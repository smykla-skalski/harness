use serde_json::json;

use crate::session::types::SessionMetrics;

use super::*;

#[test]
fn sync_session_with_agents_and_tasks() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let context: String = db
        .conn
        .query_row(
            "SELECT context FROM sessions WHERE session_id = ?1",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("query session");
    assert_eq!(context, "test session");

    let agent_count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM agents WHERE session_id = ?1",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("count agents");
    assert_eq!(agent_count, 1);

    let task_count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM tasks WHERE session_id = ?1",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("count tasks");
    assert_eq!(task_count, 1);
}

#[test]
fn sync_session_projects_managed_agent_identity_for_supported_kinds() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let state = sample_session_state_with_managed_agents();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    assert_eq!(
        session_agent_identity_rows(&db.conn, &state.session_id),
        vec![
            (
                "acp-worker".into(),
                Some("acp".into()),
                Some("acp-agent-1".into()),
            ),
            (
                "claude-leader".into(),
                Some("tui".into()),
                Some("agent-tui-1".into()),
            ),
            ("codex-worker".into(), None, None,),
            ("unmanaged-reviewer".into(), None, None),
        ]
    );
}

#[test]
fn load_session_state_round_trips_managed_agent_identity_after_sync() {
    use crate::session::types::ManagedAgentRef;

    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let state = sample_session_state_with_managed_agents();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let loaded = db
        .load_session_state(&state.session_id)
        .expect("load session")
        .expect("session present");
    assert_eq!(
        loaded
            .agents
            .get("claude-leader")
            .and_then(|agent| agent.managed_agent.clone()),
        Some(ManagedAgentRef::tui("agent-tui-1"))
    );
    assert_eq!(
        loaded
            .agents
            .get("acp-worker")
            .and_then(|agent| agent.managed_agent.clone()),
        Some(ManagedAgentRef::acp("acp-agent-1"))
    );
    assert_eq!(
        loaded
            .agents
            .get("codex-worker")
            .and_then(|agent| agent.managed_agent.clone()),
        None
    );
    assert_eq!(
        loaded
            .agents
            .get("unmanaged-reviewer")
            .and_then(|agent| agent.managed_agent.clone()),
        None
    );
}

#[test]
fn sync_session_replaces_agents_on_update() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let mut state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("first sync");

    state.agents.clear();
    state.state_version = 2;
    db.sync_session(&project.project_id, &state)
        .expect("second sync");

    let agent_count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM agents WHERE session_id = ?1",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("count agents");
    assert_eq!(agent_count, 0);
}

#[test]
fn sync_session_canonicalizes_active_sessions_without_leader() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let mut state = sample_session_state();
    state.agents.clear();
    state.leader_id = None;
    state.status = SessionStatus::Active;
    state.metrics = SessionMetrics::recalculate(&state);
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let (stored_status, stored_leader_id): (String, Option<String>) = db
        .conn
        .query_row(
            "SELECT status, leader_id
                 FROM sessions
                 WHERE session_id = ?1",
            [&state.session_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("query persisted session");
    assert_eq!(stored_status, "leaderless_degraded");
    assert!(stored_leader_id.is_none());

    let loaded = db
        .load_session_state(&state.session_id)
        .expect("load session")
        .expect("session present");
    assert_eq!(loaded.status, SessionStatus::LeaderlessDegraded);
    assert!(loaded.leader_id.is_none());
    assert_eq!(
        loaded.schema_version,
        crate::session::types::CURRENT_VERSION
    );

    let summaries = db.list_session_summaries_full().expect("session summaries");
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].status, SessionStatus::LeaderlessDegraded);
    assert!(summaries[0].leader_id.is_none());
}

#[test]
fn list_session_summaries_repair_legacy_active_rows_and_state_payloads() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let mut state = sample_session_state();
    state.agents.clear();
    state.leader_id = None;
    state.status = SessionStatus::Active;
    state.metrics = SessionMetrics::recalculate(&state);
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let legacy_payload = json!({
        "schema_version": 6,
        "state_version": 1,
        "session_id": state.session_id.clone(),
        "title": state.title.clone(),
        "context": state.context.clone(),
        "status": "active",
        "created_at": state.created_at.clone(),
        "updated_at": state.updated_at.clone(),
        "agents": {},
        "tasks": {},
        "leader_id": null,
        "archived_at": null,
        "last_activity_at": state.last_activity_at.clone(),
        "observe_id": state.observe_id.clone(),
        "pending_leader_transfer": null,
        "metrics": {
            "agent_count": 0,
            "active_agent_count": 0,
            "idle_agent_count": 0,
            "open_task_count": 0,
            "in_progress_task_count": 0,
            "blocked_task_count": 0,
            "completed_task_count": 0
        }
    })
    .to_string();
    db.conn
        .execute(
            "UPDATE sessions
             SET status = 'active',
                 leader_id = NULL,
                 metrics_json = ?1,
                 state_json = ?2,
                 is_active = 1
             WHERE session_id = ?3",
            rusqlite::params![
                json!({
                    "agent_count": 0,
                    "active_agent_count": 0,
                    "idle_agent_count": 0,
                    "open_task_count": 0,
                    "in_progress_task_count": 0,
                    "blocked_task_count": 0,
                    "completed_task_count": 0
                })
                .to_string(),
                legacy_payload,
                state.session_id.clone(),
            ],
        )
        .expect("corrupt session row");

    let summaries = db.list_session_summaries_full().expect("session summaries");
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].status, SessionStatus::LeaderlessDegraded);
    assert!(summaries[0].leader_id.is_none());

    let (stored_status, stored_state_json): (String, String) = db
        .conn
        .query_row(
            "SELECT status, state_json
                 FROM sessions
                WHERE session_id = ?1",
            [&state.session_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("load repaired row");
    let repaired_state: SessionState =
        serde_json::from_str(&stored_state_json).expect("parse repaired state");
    assert_eq!(stored_status, "leaderless_degraded");
    assert_eq!(repaired_state.status, SessionStatus::LeaderlessDegraded);
    assert!(repaired_state.leader_id.is_none());
    assert_eq!(
        repaired_state.schema_version,
        crate::session::types::CURRENT_VERSION
    );
}

#[test]
fn sync_session_preserves_leaderless_degraded_status_for_summaries() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let mut state = sample_session_state();
    state.status = SessionStatus::LeaderlessDegraded;
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let stored_status: String = db
        .conn
        .query_row(
            "SELECT status FROM sessions WHERE session_id = ?1",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("query status");
    assert_eq!(stored_status, "leaderless_degraded");

    let summaries = db.list_session_summaries_full().expect("session summaries");
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].status, SessionStatus::LeaderlessDegraded);
}

#[test]
fn list_session_summaries_full_fast_path_maps_state_only_fields() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    // Active session with a leader is non-legacy, so the summary is built from
    // the scalar columns plus the lightweight state_json projection rather than
    // a full session-state parse. Distinctive path fields guard that mapping.
    let mut state = sample_session_state();
    state.status = SessionStatus::Active;
    state.worktree_path = std::path::PathBuf::from("/tmp/wt-distinct");
    state.shared_path = std::path::PathBuf::from("/tmp/shared-distinct");
    state.origin_path = std::path::PathBuf::from("/tmp/origin-distinct");
    state.branch_ref = "harness/distinct-branch".into();
    state.external_origin = Some(std::path::PathBuf::from("/tmp/ext-origin"));
    state.adopted_at = Some("2026-04-03T12:09:00Z".into());
    state.metrics = SessionMetrics::recalculate(&state);
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let summaries = db.list_session_summaries_full().expect("session summaries");
    let summary = summaries
        .iter()
        .find(|summary| summary.session_id == state.session_id)
        .expect("summary present");

    assert_eq!(summary.status, SessionStatus::Active);
    assert_eq!(summary.leader_id, state.leader_id);
    assert_eq!(summary.worktree_path, "/tmp/wt-distinct");
    assert_eq!(summary.shared_path, "/tmp/shared-distinct");
    assert_eq!(summary.origin_path, "/tmp/origin-distinct");
    assert_eq!(summary.branch_ref, "harness/distinct-branch");
    assert_eq!(summary.external_origin.as_deref(), Some("/tmp/ext-origin"));
    assert_eq!(summary.adopted_at.as_deref(), Some("2026-04-03T12:09:00Z"));
    assert_eq!(summary.metrics, state.metrics);
}

#[test]
fn append_log_entry_inserts() {
    use crate::session::types::SessionTransition;

    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    let state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let entry = SessionLogEntry {
        sequence: 1,
        recorded_at: "2026-04-03T12:00:00Z".into(),
        session_id: state.session_id.clone(),
        transition: SessionTransition::SessionStarted {
            title: "test title".into(),
            context: "test".into(),
        },
        actor_id: Some("claude-leader".into()),
        reason: None,
    };
    db.append_log_entry(&entry).expect("append log entry");

    let count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM session_log WHERE session_id = ?1",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("count log entries");
    assert_eq!(count, 1);
}

#[test]
fn append_log_entry_updates_session_timeline_revision_and_count() {
    use crate::session::types::SessionTransition;

    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    let state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let entry = SessionLogEntry {
        sequence: 1,
        recorded_at: "2026-04-03T12:00:00Z".into(),
        session_id: state.session_id.clone(),
        transition: SessionTransition::SessionStarted {
            title: "test title".into(),
            context: "test".into(),
        },
        actor_id: Some("claude-leader".into()),
        reason: None,
    };
    db.append_log_entry(&entry).expect("append log entry");

    let (revision, entry_count): (i64, i64) = db
        .conn
        .query_row(
            "SELECT revision, entry_count
                 FROM session_timeline_state
                 WHERE session_id = ?1",
            [&state.session_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("load timeline state");
    assert_eq!(revision, 1);
    assert_eq!(entry_count, 1);

    let summary: String = db
        .conn
        .query_row(
            "SELECT summary
                 FROM session_timeline_entries
                 WHERE session_id = ?1 AND source_kind = 'log' AND source_key = 'log:1'",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("load timeline summary");
    assert_eq!(summary, "Session started: test title - test");
}
