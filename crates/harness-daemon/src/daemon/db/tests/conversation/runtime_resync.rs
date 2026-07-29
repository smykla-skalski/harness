use super::*;

#[test]
fn prepare_runtime_transcript_resync_only_loads_matching_agent() {
    use crate::agents::runtime::RuntimeCapabilities;
    use crate::session::types::{AgentRegistration, AgentStatus, SessionRole};

    let mut state = sample_session_state();
    state.agents.insert(
        "codex-worker".into(),
        AgentRegistration {
            agent_id: "codex-worker".into(),
            name: "Codex Worker".into(),
            runtime: "codex".into(),
            role: SessionRole::Worker,
            capabilities: vec!["general".into()],
            joined_at: "2026-04-03T12:01:00Z".into(),
            updated_at: "2026-04-03T12:05:30Z".into(),
            status: AgentStatus::Active,
            agent_session_id: Some("codex-session-1".into()),
            managed_agent: None,
            last_activity_at: Some("2026-04-03T12:05:30Z".into()),
            current_task_id: None,
            runtime_capabilities: RuntimeCapabilities::default(),
            persona: None,
            runtime_session_title: None,
        },
    );
    let session_id = state.session_id.clone();

    let mut calls = Vec::new();
    let prepared = prepare_runtime_transcript_resync_for_agents(
        &state,
        "codex",
        "codex-session-1",
        |agent_id, runtime, session_key| {
            calls.push((
                agent_id.to_string(),
                runtime.to_string(),
                session_key.to_string(),
            ));
            Ok(vec![ConversationEvent {
                timestamp: Some("2026-04-03T12:00:03Z".into()),
                sequence: 1,
                kind: ConversationEventKind::ToolInvocation {
                    tool_name: "Read".into(),
                    category: "fs".into(),
                    input: serde_json::json!({"path": "README.md"}),
                    invocation_id: Some("call-1".into()),
                },
                agent: agent_id.to_string(),
                session_id: session_id.clone(),
            }])
        },
    )
    .expect("prepare runtime transcript refresh");

    assert_eq!(
        calls,
        vec![(
            "codex-worker".to_string(),
            "codex".to_string(),
            "codex-session-1".to_string(),
        )]
    );
    assert_eq!(prepared.len(), 1);
    assert_eq!(prepared[0].agent_id, "codex-worker");
    assert_eq!(prepared[0].runtime, "codex");
    assert_eq!(prepared[0].events.len(), 1);
    assert_eq!(prepared[0].activity.agent_id, "codex-worker");
    assert_eq!(prepared[0].activity.tool_invocation_count, 1);
}

#[test]
fn apply_prepared_runtime_transcript_resync_preserves_other_agents() {
    use crate::agents::runtime::RuntimeCapabilities;
    use crate::session::types::{AgentRegistration, AgentStatus, SessionRole};

    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let mut state = sample_session_state();
    state.agents.insert(
        "codex-worker".into(),
        AgentRegistration {
            agent_id: "codex-worker".into(),
            name: "Codex Worker".into(),
            runtime: "codex".into(),
            role: SessionRole::Worker,
            capabilities: vec!["general".into()],
            joined_at: "2026-04-03T12:01:00Z".into(),
            updated_at: "2026-04-03T12:05:30Z".into(),
            status: AgentStatus::Active,
            agent_session_id: Some("codex-session-1".into()),
            managed_agent: None,
            last_activity_at: Some("2026-04-03T12:05:30Z".into()),
            current_task_id: None,
            runtime_capabilities: RuntimeCapabilities::default(),
            persona: None,
            runtime_session_title: None,
        },
    );
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    db.sync_conversation_events(
        &state.session_id,
        "claude-leader",
        "claude",
        &[ConversationEvent {
            timestamp: Some("2026-04-03T12:00:01Z".into()),
            sequence: 1,
            kind: ConversationEventKind::ToolInvocation {
                tool_name: "Read".into(),
                category: "fs".into(),
                input: serde_json::json!({"path": "README.md"}),
                invocation_id: Some("claude-1".into()),
            },
            agent: "claude-leader".into(),
            session_id: state.session_id.clone(),
        }],
    )
    .expect("seed leader conversation");
    db.sync_conversation_events(
        &state.session_id,
        "codex-worker",
        "codex",
        &[ConversationEvent {
            timestamp: Some("2026-04-03T12:00:02Z".into()),
            sequence: 1,
            kind: ConversationEventKind::ToolInvocation {
                tool_name: "Write".into(),
                category: "fs".into(),
                input: serde_json::json!({"path": "main.rs"}),
                invocation_id: Some("codex-1".into()),
            },
            agent: "codex-worker".into(),
            session_id: state.session_id.clone(),
        }],
    )
    .expect("seed worker conversation");
    db.sync_agent_activity(
        &state.session_id,
        &[
            daemon_protocol::AgentToolActivitySummary {
                agent_id: "claude-leader".into(),
                runtime: "claude".into(),
                tool_invocation_count: 1,
                tool_result_count: 0,
                tool_error_count: 0,
                latest_tool_name: Some("Read".into()),
                latest_event_at: Some("2026-04-03T12:00:01Z".into()),
                recent_tools: vec!["Read".into()],
                pending_user_prompt: None,
            },
            daemon_protocol::AgentToolActivitySummary {
                agent_id: "codex-worker".into(),
                runtime: "codex".into(),
                tool_invocation_count: 1,
                tool_result_count: 0,
                tool_error_count: 0,
                latest_tool_name: Some("Write".into()),
                latest_event_at: Some("2026-04-03T12:00:02Z".into()),
                recent_tools: vec!["Write".into()],
                pending_user_prompt: None,
            },
        ],
    )
    .expect("seed activity cache");

    let prepared_agents = prepare_runtime_transcript_resync_for_agents(
        &state,
        "codex",
        "codex-session-1",
        |_agent_id: &str, _runtime: &str, _session_key: &str| {
            Ok(vec![
                ConversationEvent {
                    timestamp: Some("2026-04-03T12:00:02Z".into()),
                    sequence: 1,
                    kind: ConversationEventKind::ToolInvocation {
                        tool_name: "Write".into(),
                        category: "fs".into(),
                        input: serde_json::json!({"path": "main.rs"}),
                        invocation_id: Some("codex-1".into()),
                    },
                    agent: "codex-worker".into(),
                    session_id: state.session_id.clone(),
                },
                ConversationEvent {
                    timestamp: Some("2026-04-03T12:00:03Z".into()),
                    sequence: 2,
                    kind: ConversationEventKind::ToolResult {
                        tool_name: "Write".into(),
                        invocation_id: Some("codex-1".into()),
                        output: serde_json::json!({"ok": true}),
                        is_error: false,
                        duration_ms: Some(4),
                    },
                    agent: "codex-worker".into(),
                    session_id: state.session_id.clone(),
                },
            ])
        },
    )
    .expect("prepare worker transcript refresh");
    db.apply_prepared_runtime_transcript_resync(&PreparedRuntimeTranscriptResync {
        session_id: state.session_id.clone(),
        agents: prepared_agents,
    })
    .expect("apply worker transcript refresh");

    let activities = db
        .load_agent_activity(&state.session_id)
        .expect("load activity cache");
    assert_eq!(activities.len(), 2);
    assert_eq!(activities[0].agent_id, "claude-leader");
    assert_eq!(activities[0].latest_tool_name.as_deref(), Some("Read"));
    assert_eq!(activities[1].agent_id, "codex-worker");
    assert_eq!(activities[1].tool_result_count, 1);

    let leader_events = db
        .load_conversation_events(&state.session_id, "claude-leader")
        .expect("load leader events");
    let worker_events = db
        .load_conversation_events(&state.session_id, "codex-worker")
        .expect("load worker events");
    assert_eq!(leader_events.len(), 1);
    assert_eq!(worker_events.len(), 2);
}

#[test]
fn append_conversation_events_merges_live_batches_without_replacing_history() {
    let db = DaemonDb::open_in_memory().expect("open db");
    seed_conversation_session(&db);

    let first = ConversationEvent {
        timestamp: Some("2026-04-03T12:00:01Z".into()),
        sequence: 1,
        kind: ConversationEventKind::AssistantText {
            content: "first response".into(),
            message_id: None,
        },
        agent: "claude-leader".into(),
        session_id: "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".into(),
    };
    let second = ConversationEvent {
        timestamp: Some("2026-04-03T12:00:02Z".into()),
        sequence: 2,
        kind: ConversationEventKind::AssistantText {
            content: "second response".into(),
            message_id: None,
        },
        agent: "claude-leader".into(),
        session_id: "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".into(),
    };

    db.append_conversation_events(
        "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
        "claude-leader",
        "gemini",
        &[first.clone()],
    )
    .expect("append first live batch");
    db.append_conversation_events(
        "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
        "claude-leader",
        "gemini",
        &[first],
    )
    .expect("reappend identical live batch");
    db.append_conversation_events(
        "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
        "claude-leader",
        "gemini",
        &[second],
    )
    .expect("append second live batch");

    let loaded = db
        .load_conversation_events("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4", "claude-leader")
        .expect("load appended events");
    assert_eq!(loaded.len(), 2);
    assert_eq!(loaded[0].sequence, 1);
    assert_eq!(loaded[1].sequence, 2);

    let timeline = db
        .load_session_timeline_window(
            "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
            &TimelineWindowRequest::default(),
        )
        .expect("load timeline window")
        .expect("timeline window present");
    assert_eq!(timeline.total_count, 2);
    let entries = timeline.entries.expect("timeline entries present");
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].summary, "second response");
    assert_eq!(entries[1].summary, "first response");
}

fn worker_event_rows(db: &DaemonDb, session_id: &str) -> Vec<(i64, i64)> {
    let mut statement = db
        .conn
        .prepare(
            "SELECT sequence, id FROM conversation_events
             WHERE session_id = ?1 AND agent_id = ?2
             ORDER BY sequence",
        )
        .expect("prepare conversation row id query");
    let rows = statement
        .query_map(rusqlite::params![session_id, "codex-worker"], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?))
        })
        .expect("query conversation row ids");
    rows.map(|row| row.expect("conversation row id")).collect()
}

fn worker_state() -> SessionState {
    use crate::agents::runtime::RuntimeCapabilities;
    use crate::session::types::{AgentRegistration, AgentStatus, SessionRole};

    let mut state = sample_session_state();
    state.agents.insert(
        "codex-worker".into(),
        AgentRegistration {
            agent_id: "codex-worker".into(),
            name: "Codex Worker".into(),
            runtime: "codex".into(),
            role: SessionRole::Worker,
            capabilities: vec!["general".into()],
            joined_at: "2026-04-03T12:01:00Z".into(),
            updated_at: "2026-04-03T12:05:30Z".into(),
            status: AgentStatus::Active,
            agent_session_id: Some("codex-session-1".into()),
            managed_agent: None,
            last_activity_at: Some("2026-04-03T12:05:30Z".into()),
            current_task_id: None,
            runtime_capabilities: RuntimeCapabilities::default(),
            persona: None,
            runtime_session_title: None,
        },
    );
    state
}

fn worker_event(sequence: u64, timestamp: &str) -> ConversationEvent {
    ConversationEvent {
        timestamp: Some(timestamp.into()),
        sequence,
        kind: ConversationEventKind::AssistantText {
            content: format!("response {sequence}"),
            message_id: None,
        },
        agent: "codex-worker".into(),
        session_id: "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".into(),
    }
}

#[test]
fn apply_prepared_runtime_transcript_resync_preserves_existing_event_rows() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let state = worker_state();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let seq_one = worker_event(1, "2026-04-03T12:00:02Z");
    let seq_two = worker_event(2, "2026-04-03T12:00:03Z");
    db.sync_conversation_events(
        &state.session_id,
        "codex-worker",
        "codex",
        &[seq_one.clone(), seq_two.clone()],
    )
    .expect("seed worker conversation");

    let before = worker_event_rows(&db, &state.session_id);
    assert_eq!(before.len(), 2);

    let seq_three = worker_event(3, "2026-04-03T12:00:04Z");
    let prepared_agents = prepare_runtime_transcript_resync_for_agents(
        &state,
        "codex",
        "codex-session-1",
        |_agent_id: &str, _runtime: &str, _session_key: &str| {
            Ok(vec![seq_one.clone(), seq_two.clone(), seq_three.clone()])
        },
    )
    .expect("prepare worker transcript refresh");
    db.apply_prepared_runtime_transcript_resync(&PreparedRuntimeTranscriptResync {
        session_id: state.session_id.clone(),
        agents: prepared_agents,
    })
    .expect("apply worker transcript refresh");

    let after = worker_event_rows(&db, &state.session_id);
    assert_eq!(after.len(), 3);
    // The unchanged prefix keeps its stored row identity (no delete + reinsert).
    assert_eq!(after[0], before[0]);
    assert_eq!(after[1], before[1]);
    // Only the new tail event is inserted, with a fresh row id.
    assert_eq!(after[2].0, 3);
    assert!(after[2].1 > before[1].1);
}

#[test]
fn apply_prepared_runtime_transcript_resync_replaces_when_transcript_shrinks() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let state = worker_state();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    db.sync_conversation_events(
        &state.session_id,
        "codex-worker",
        "codex",
        &[
            worker_event(1, "2026-04-03T12:00:01Z"),
            worker_event(2, "2026-04-03T12:00:02Z"),
            worker_event(3, "2026-04-03T12:00:03Z"),
        ],
    )
    .expect("seed worker conversation");

    let seq_one = worker_event(1, "2026-04-03T12:00:01Z");
    let prepared_agents = prepare_runtime_transcript_resync_for_agents(
        &state,
        "codex",
        "codex-session-1",
        |_agent_id: &str, _runtime: &str, _session_key: &str| Ok(vec![seq_one.clone()]),
    )
    .expect("prepare worker transcript refresh");
    db.apply_prepared_runtime_transcript_resync(&PreparedRuntimeTranscriptResync {
        session_id: state.session_id.clone(),
        agents: prepared_agents,
    })
    .expect("apply worker transcript refresh");

    let events = db
        .load_conversation_events(&state.session_id, "codex-worker")
        .expect("load worker events");
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].sequence, 1);
}
