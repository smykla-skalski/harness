use harness_protocol::agent::{AckResult, ConversationEvent, ConversationEventKind};
use harness_protocol::timeline::{TimelineCursor, TimelineWindowRequest};
use sqlx::{query, query_scalar};

use super::super::AsyncAgentWorkspaceTeamQueries;
use super::support::{DAEMON_ID, Fixture, NOW};
use crate::{
    AgentWorkspaceSignalAcknowledgment, AsyncAgentWorkspaceActivityQueries,
    AsyncAgentWorkspaceQueries,
};

#[tokio::test]
async fn activity_backfill_is_ordered_restart_safe_and_survives_session_deletion() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-activity", "session-activity")
        .await;
    fixture
        .seed_agent(
            "session-activity",
            "agent-activity",
            "acp",
            "acp-activity",
            "runtime-activity",
        )
        .await;
    let member_id = reconcile_member(&fixture, &workspace_id).await;
    seed_activity(&fixture, &workspace_id).await;

    let first = fixture
        .db
        .load_agent_workspace_activity(DAEMON_ID, &workspace_id, &TimelineWindowRequest::default())
        .await
        .expect("backfill durable activity");
    assert_eq!(first.total_count, 1);
    assert_eq!(first.entries.as_ref().map(Vec::len), Some(1));
    let member = fixture
        .db
        .load_agent_workspace_member_activity(DAEMON_ID, &workspace_id, &member_id)
        .await
        .expect("load durable member activity");
    assert!(member.activity.is_some());
    assert_eq!(member.conversation.len(), 2);
    assert_eq!(member.conversation[0].event.sequence, 1);
    assert_eq!(member.conversation[1].event.sequence, 2);
    assert_eq!(member.signals.len(), 1);

    query(
        "UPDATE session_timeline_entries
         SET summary = 'Revised observed output'
         WHERE session_id = 'session-activity' AND entry_id = 'entry-1'",
    )
    .execute(fixture.db.pool())
    .await
    .expect("update visible legacy timeline content");
    let refreshed = fixture
        .db
        .load_agent_workspace_activity(
            DAEMON_ID,
            &workspace_id,
            &TimelineWindowRequest {
                known_revision: Some(first.revision),
                ..TimelineWindowRequest::default()
            },
        )
        .await
        .expect("reload changed durable activity");
    assert!(!refreshed.unchanged);
    assert!(
        refreshed
            .entries
            .as_ref()
            .is_some_and(|entries| entries[0].summary == "Revised observed output")
    );

    let unchanged = fixture
        .db
        .load_agent_workspace_activity(
            DAEMON_ID,
            &workspace_id,
            &TimelineWindowRequest {
                known_revision: Some(refreshed.revision),
                ..TimelineWindowRequest::default()
            },
        )
        .await
        .expect("repeat durable activity read");
    assert!(unchanged.unchanged);
    assert!(unchanged.entries.is_none());

    assert_activity_survives_session_deletion(&fixture, &workspace_id, &member_id).await;
}

#[tokio::test]
async fn session_deletion_rejects_unmapped_observation_records() {
    let fixture = Fixture::new().await;
    fixture
        .seed_workspace("project-unmapped-activity", "session-unmapped-activity")
        .await;
    let signal = harness_session::service::build_signal(
        "test",
        "inspect",
        "inspect",
        None,
        "session-unmapped-activity",
        "agent-unmapped",
        NOW,
    );
    insert_signal(
        &fixture,
        "session-unmapped-activity",
        "agent-unmapped",
        &signal,
    )
    .await;

    let error = query("DELETE FROM sessions WHERE session_id = 'session-unmapped-activity'")
        .execute(fixture.db.pool())
        .await
        .expect_err("unmapped observation must block deletion");
    assert!(
        error
            .to_string()
            .contains("cannot detach Session before agent activity reconciliation")
            || error
                .to_string()
                .contains("cannot detach Session with unmapped agent activity")
    );
}

#[tokio::test]
async fn conflicting_activity_cursors_are_rejected() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-conflicting-cursors", "session-conflicting-cursors")
        .await;
    fixture
        .seed_agent(
            "session-conflicting-cursors",
            "agent-conflicting-cursors",
            "acp",
            "acp-conflicting-cursors",
            "runtime-conflicting-cursors",
        )
        .await;
    reconcile_member(&fixture, &workspace_id).await;
    let cursor = TimelineCursor {
        recorded_at: NOW.to_string(),
        entry_id: "entry-conflicting-cursors".to_string(),
    };

    let error = fixture
        .db
        .load_agent_workspace_activity(
            DAEMON_ID,
            &workspace_id,
            &TimelineWindowRequest {
                before: Some(cursor.clone()),
                after: Some(cursor),
                ..TimelineWindowRequest::default()
            },
        )
        .await
        .expect_err("conflicting activity cursors must fail");

    assert!(error.to_string().contains("both before and after cursors"));
}

#[tokio::test]
async fn native_signal_and_ack_use_workspace_member_ownership() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-native-signal", "session-native-signal")
        .await;
    fixture
        .seed_agent(
            "session-native-signal",
            "agent-native",
            "codex",
            "run-native",
            "thread-native",
        )
        .await;
    let member_id = reconcile_member(&fixture, &workspace_id).await;
    let target = fixture
        .db
        .load_agent_workspace_signal_target(DAEMON_ID, &workspace_id, &member_id)
        .await
        .expect("load native durable signal target");
    let project_dir = query_scalar::<_, String>(
        "SELECT project_dir FROM agent_workspaces WHERE workspace_id = ?1",
    )
    .bind(&workspace_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load durable workspace project directory");
    assert_eq!(target.project_dir, project_dir);
    let signal = harness_session::service::build_signal(
        "test",
        "continue",
        "continue work",
        None,
        &workspace_id,
        &member_id,
        NOW,
    );
    let inserted = fixture
        .db
        .insert_agent_workspace_signal(DAEMON_ID, &workspace_id, &member_id, &target, &signal)
        .await
        .expect("insert native durable signal");
    assert!(inserted.inserted);
    assert_eq!(inserted.record.member_id, member_id);
    assert!(inserted.record.legacy_session_id.is_none());
    let revision_after_insert = timeline_revision(&fixture, &workspace_id).await;
    let retried = fixture
        .db
        .insert_agent_workspace_signal(DAEMON_ID, &workspace_id, &member_id, &target, &signal)
        .await
        .expect("repeat native durable signal insert");
    assert!(!retried.inserted);
    assert_eq!(retried.record.signal.signal_id, signal.signal_id);
    assert_eq!(
        timeline_revision(&fixture, &workspace_id).await,
        revision_after_insert,
        "an idempotent signal retry must not advance the timeline revision"
    );

    assert_signal_acknowledgment_is_idempotent(&fixture, &workspace_id, &member_id, &signal).await;
    query(
        "UPDATE agent_workspace_members SET runtime_lifecycle = 'completed'
         WHERE workspace_id = ?1 AND member_id = ?2",
    )
    .bind(&workspace_id)
    .bind(&member_id)
    .execute(fixture.db.pool())
    .await
    .expect("complete durable runtime");
    fixture
        .db
        .load_agent_workspace_signal_target(DAEMON_ID, &workspace_id, &member_id)
        .await
        .expect_err("completed durable runtime must reject new signals");
}

#[tokio::test]
async fn missing_activity_cursor_does_not_alias_the_newest_entry() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-activity-cursor", "session-activity-cursor")
        .await;
    fixture
        .seed_agent(
            "session-activity-cursor",
            "agent-activity-cursor",
            "acp",
            "acp-activity-cursor",
            "runtime-activity-cursor",
        )
        .await;
    reconcile_member(&fixture, &workspace_id).await;
    for (entry_id, recorded_at) in [
        ("entry-cursor-1", "2026-08-06T10:00:00Z"),
        ("entry-cursor-2", "2026-08-06T10:00:01Z"),
    ] {
        query(
            "INSERT INTO session_timeline_entries (
                session_id, entry_id, source_kind, source_key, recorded_at, kind,
                agent_id, task_id, summary, payload_json, sort_recorded_at,
                sort_tiebreaker
             ) VALUES ('session-activity-cursor', ?1, 'conversation', ?2,
                       ?3, 'assistant_text', 'agent-activity-cursor', NULL,
                       'Observed output', '{}', ?3, ?1)",
        )
        .bind(entry_id)
        .bind(format!("conversation:{entry_id}"))
        .bind(recorded_at)
        .execute(fixture.db.pool())
        .await
        .expect("insert cursor timeline entry");
    }

    let response = fixture
        .db
        .load_agent_workspace_activity(
            DAEMON_ID,
            &workspace_id,
            &TimelineWindowRequest {
                limit: Some(1),
                before: Some(TimelineCursor {
                    recorded_at: "missing".to_string(),
                    entry_id: "missing".to_string(),
                }),
                ..TimelineWindowRequest::default()
            },
        )
        .await
        .expect("load activity from missing cursor");
    assert_eq!(response.window_start, response.total_count);
    assert_eq!(response.entries.as_ref().map(Vec::len), Some(0));
}

async fn assert_activity_survives_session_deletion(
    fixture: &Fixture,
    workspace_id: &str,
    member_id: &str,
) {
    query("DELETE FROM sessions WHERE session_id = 'session-activity'")
        .execute(fixture.db.pool())
        .await
        .expect("detach reconciled Session");
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("reconcile detached workspace");
    let preserved = fixture
        .db
        .load_agent_workspace_member_activity(DAEMON_ID, workspace_id, member_id)
        .await
        .expect("load activity after Session deletion");
    assert_eq!(preserved.conversation.len(), 2);
    assert_eq!(preserved.signals.len(), 1);
    let timeline = fixture
        .db
        .load_agent_workspace_activity(DAEMON_ID, workspace_id, &TimelineWindowRequest::default())
        .await
        .expect("load timeline after Session deletion");
    assert_eq!(timeline.total_count, 1);
    assert_eq!(timeline.entries.as_ref().map(Vec::len), Some(1));
    let detached = query_scalar::<_, String>(
        "SELECT status FROM agent_workspace_activity_sources
         WHERE workspace_id = ?1 AND source_session_id = 'session-activity'",
    )
    .bind(workspace_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load detached source status");
    assert_eq!(detached, "detached");
}

async fn assert_signal_acknowledgment_is_idempotent(
    fixture: &Fixture,
    workspace_id: &str,
    member_id: &str,
    signal: &harness_protocol::agent::Signal,
) {
    let acknowledgment = AgentWorkspaceSignalAcknowledgment {
        signal_id: signal.signal_id.clone(),
        result: AckResult::Accepted,
        details: Some("received".to_string()),
        acknowledged_at: None,
    };
    let acknowledged = fixture
        .db
        .acknowledge_agent_workspace_signal(DAEMON_ID, workspace_id, member_id, &acknowledgment)
        .await
        .expect("acknowledge native durable signal");
    assert_eq!(
        acknowledged.status,
        harness_protocol::session::SessionSignalStatus::Delivered
    );
    assert!(acknowledged.acknowledgment.is_some());
    let revision_after_ack = timeline_revision(fixture, workspace_id).await;
    fixture
        .db
        .acknowledge_agent_workspace_signal(DAEMON_ID, workspace_id, member_id, &acknowledgment)
        .await
        .expect("repeat native durable signal acknowledgment");
    assert_eq!(
        timeline_revision(fixture, workspace_id).await,
        revision_after_ack,
        "an idempotent acknowledgment retry must not advance the timeline revision"
    );
    let target = fixture
        .db
        .load_agent_workspace_signal_target(DAEMON_ID, workspace_id, member_id)
        .await
        .expect("load acknowledged signal target");
    let retried = fixture
        .db
        .insert_agent_workspace_signal(DAEMON_ID, workspace_id, member_id, &target, signal)
        .await
        .expect("repeat acknowledged durable signal insert");
    assert!(!retried.inserted);
    assert_eq!(
        timeline_revision(fixture, workspace_id).await,
        revision_after_ack,
        "an acknowledged signal retry must preserve its original idempotency identity"
    );
}

async fn reconcile_member(fixture: &Fixture, workspace_id: &str) -> String {
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("reconcile workspace and activity");
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, workspace_id)
        .await
        .expect("reconcile durable member")
        .team
        .expect("durable team")
        .members[0]
        .member_id
        .clone()
}

async fn seed_activity(fixture: &Fixture, workspace_id: &str) {
    let signal = harness_session::service::build_signal(
        "test",
        "inspect",
        "inspect state",
        None,
        "session-activity",
        "agent-activity",
        NOW,
    );
    insert_signal(fixture, "session-activity", "agent-activity", &signal).await;
    for sequence in [2, 1] {
        let event = ConversationEvent {
            timestamp: Some(format!("2026-08-06T10:00:0{sequence}Z")),
            sequence,
            kind: ConversationEventKind::AssistantText {
                content: format!("event {sequence}"),
                message_id: None,
            },
            agent: "agent-activity".to_string(),
            session_id: "session-activity".to_string(),
        };
        query(
            "INSERT INTO conversation_events (
                session_id, agent_id, runtime, timestamp, sequence, kind, event_json
             ) VALUES ('session-activity', 'agent-activity', 'acp', ?1, ?2,
                       'assistant_text', ?3)",
        )
        .bind(event.timestamp.as_deref())
        .bind(i64::try_from(sequence).expect("sequence fits"))
        .bind(serde_json::to_string(&event).expect("serialize event"))
        .execute(fixture.db.pool())
        .await
        .expect("insert conversation event");
    }
    query(
        "INSERT INTO agent_activity_cache (
            agent_id, session_id, runtime, activity_json, cached_at
         ) VALUES ('agent-activity', 'session-activity', 'acp',
                   '{\"tool_count\":2}', ?1)",
    )
    .bind(NOW)
    .execute(fixture.db.pool())
    .await
    .expect("insert activity summary");
    query(
        "INSERT INTO session_timeline_entries (
            session_id, entry_id, source_kind, source_key, recorded_at, kind,
            agent_id, task_id, summary, payload_json, sort_recorded_at, sort_tiebreaker
         ) VALUES ('session-activity', 'entry-1', 'conversation', 'conversation:1',
                   ?1, 'assistant_text', 'agent-activity', NULL, 'Observed output', '{}',
                   ?1, 'entry-1')",
    )
    .bind(NOW)
    .execute(fixture.db.pool())
    .await
    .expect("insert timeline entry");
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("project durable activity");
    let source_count = query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM agent_workspace_activity_sources WHERE workspace_id = ?1",
    )
    .bind(workspace_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("count activity sources");
    assert_eq!(source_count, 1);
}

async fn insert_signal(
    fixture: &Fixture,
    session_id: &str,
    agent_id: &str,
    signal: &harness_protocol::agent::Signal,
) {
    query(
        "INSERT INTO signal_index (
            signal_id, session_id, agent_id, runtime, command, priority, status,
            created_at, source_agent, message, action_hint, signal_json, ack_json,
            file_path, indexed_at
         ) VALUES (?1, ?2, ?3, 'acp', ?4, 'normal', 'pending', ?5, ?6, ?7,
                   NULL, ?8, NULL, '', ?5)",
    )
    .bind(&signal.signal_id)
    .bind(session_id)
    .bind(agent_id)
    .bind(&signal.command)
    .bind(&signal.created_at)
    .bind(&signal.source_agent)
    .bind(&signal.payload.message)
    .bind(serde_json::to_string(signal).expect("serialize signal"))
    .execute(fixture.db.pool())
    .await
    .expect("insert legacy signal");
}

async fn timeline_revision(fixture: &Fixture, workspace_id: &str) -> i64 {
    query_scalar("SELECT revision FROM agent_workspace_timeline_state WHERE workspace_id = ?1")
        .bind(workspace_id)
        .fetch_one(fixture.db.pool())
        .await
        .expect("load durable timeline revision")
}
