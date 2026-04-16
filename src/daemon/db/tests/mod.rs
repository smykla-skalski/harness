pub(super) use super::*;
pub(super) use crate::agents::runtime::event::ConversationEventKind;
pub(super) use crate::daemon::{index as daemon_index, protocol as daemon_protocol};
pub(super) use std::path::{Path, PathBuf};
pub(super) use std::time::{Duration, Instant};

mod support;
#[allow(unused_imports)]
use support::*;

mod async_pool;
mod async_reads;
mod conversation;
mod mutations;
mod performance;
mod projects;
mod reconcile;
mod runtime;
mod schema;
mod schema_backfill;
mod signals;
mod sync;

#[test]
fn db_round_trip_smoke_covers_public_surface() {
    use crate::session::types::SessionTransition;

    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let state = sample_session_state();
    db.create_session_record(&project.project_id, &state)
        .expect("create session");

    assert_eq!(
        db.project_id_for_session(&state.session_id)
            .expect("project for session"),
        Some(project.project_id.clone())
    );
    assert_eq!(
        db.ensure_project_for_dir("/tmp/harness")
            .expect("ensure project"),
        project.project_id
    );
    assert_eq!(
        db.session_state_version(&state.session_id)
            .expect("state version"),
        Some(1)
    );

    let mut mutable_state = db
        .load_session_state_for_mutation(&state.session_id)
        .expect("load mutable state")
        .expect("mutable state present");
    mutable_state.context = "updated context".into();
    mutable_state.state_version = 2;
    db.save_session_state("project-abc123", &mutable_state)
        .expect("save mutable state");

    let log_entry = SessionLogEntry {
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
    db.append_log_entry(&log_entry).expect("append log entry");

    let checkpoint = TaskCheckpoint {
        checkpoint_id: "checkpoint-1".into(),
        task_id: "task-1".into(),
        recorded_at: "2026-04-03T12:01:00Z".into(),
        actor_id: Some("claude-leader".into()),
        summary: "Investigating".into(),
        progress: 25,
    };
    db.append_checkpoint(&state.session_id, &checkpoint)
        .expect("append checkpoint");

    let signal = sample_signal_record("2099-12-31T23:59:59Z");
    db.sync_signal_index(&state.session_id, std::slice::from_ref(&signal))
        .expect("sync signals");

    let events = vec![ConversationEvent {
        kind: ConversationEventKind::Error {
            code: None,
            message: "boom".into(),
            recoverable: true,
        },
        ..sample_conversation_event(1, "ignored")
    }];
    db.sync_conversation_events(&state.session_id, "claude-leader", "claude", &events)
        .expect("sync conversation events");

    let activity = daemon_protocol::AgentToolActivitySummary {
        agent_id: "claude-leader".into(),
        runtime: "claude".into(),
        tool_invocation_count: 1,
        tool_result_count: 1,
        tool_error_count: 0,
        latest_tool_name: Some("Read".into()),
        latest_event_at: Some("2026-04-03T12:00:02Z".into()),
        recent_tools: vec!["Read".into()],
    };
    db.sync_agent_activity(&state.session_id, std::slice::from_ref(&activity))
        .expect("sync agent activity");

    db.set_diagnostics_cache("smoke", "cached")
        .expect("set diagnostics cache");
    assert_eq!(
        db.get_diagnostics_cache("smoke")
            .expect("get diagnostics cache")
            .as_deref(),
        Some("cached")
    );

    db.append_daemon_event("info", "smoke event")
        .expect("append daemon event");
    let daemon_events = db.load_recent_daemon_events(5).expect("load daemon events");
    assert_eq!(daemon_events.len(), 1);
    assert_eq!(daemon_events[0].message, "smoke event");

    let codex_run = sample_codex_run("codex-smoke", "2026-04-09T11:00:00Z");
    db.save_codex_run(&codex_run).expect("save codex run");
    assert_eq!(
        db.codex_run("codex-smoke")
            .expect("load codex run")
            .map(|snapshot| snapshot.run_id),
        Some("codex-smoke".into())
    );
    assert_eq!(
        db.list_codex_runs(&state.session_id)
            .expect("list codex runs")
            .len(),
        1
    );

    let agent_tui = sample_agent_tui("agent-tui-smoke", "2026-04-09T11:00:00Z");
    db.save_agent_tui(&agent_tui).expect("save agent tui");
    assert_eq!(
        db.agent_tui("agent-tui-smoke")
            .expect("load agent tui")
            .map(|snapshot| snapshot.tui_id),
        Some("agent-tui-smoke".into())
    );
    let refresh_state = db
        .agent_tui_live_refresh_state("agent-tui-smoke")
        .expect("load live refresh state")
        .expect("refresh state present");
    assert_eq!(refresh_state.status, AgentTuiStatus::Running);
    assert_eq!(
        db.list_agent_tuis(&state.session_id)
            .expect("list agent tuis")
            .len(),
        1
    );

    let loaded_signals = db.load_signals(&state.session_id).expect("load signals");
    assert_eq!(loaded_signals.len(), 1);
    assert_eq!(loaded_signals[0].signal.signal_id, "sig-test-1");

    let loaded_events = db
        .load_conversation_events(&state.session_id, "claude-leader")
        .expect("load conversation events");
    assert_eq!(loaded_events.len(), 1);
    match &loaded_events[0].kind {
        ConversationEventKind::Error { message, .. } => assert_eq!(message, "boom"),
        other => panic!("unexpected conversation event: {other:?}"),
    }

    let loaded_activity = db
        .load_agent_activity(&state.session_id)
        .expect("load agent activity");
    assert_eq!(loaded_activity.len(), 1);
    assert_eq!(loaded_activity[0].latest_tool_name.as_deref(), Some("Read"));

    let checkpoints = db
        .load_task_checkpoints(&state.session_id, "task-1")
        .expect("load checkpoints");
    assert_eq!(checkpoints.len(), 1);
    assert_eq!(checkpoints[0].checkpoint_id, "checkpoint-1");

    let log_entries = db
        .load_session_log(&state.session_id)
        .expect("load session log");
    assert_eq!(log_entries.len(), 1);

    let resolved = db
        .resolve_session(&state.session_id)
        .expect("resolve session")
        .expect("resolved session");
    assert_eq!(resolved.state.context, "updated context");

    let timeline = db
        .load_session_timeline_window(&state.session_id, &TimelineWindowRequest::default())
        .expect("load timeline window")
        .expect("timeline window present");
    assert_eq!(timeline.total_count, 3);
    assert_eq!(timeline.entries.as_ref().map(Vec::len), Some(3));

    let project_summaries = db.list_project_summaries().expect("project summaries");
    assert_eq!(project_summaries.len(), 1);
    assert_eq!(project_summaries[0].total_session_count, 1);

    let session_summaries = db.list_session_summaries_full().expect("session summaries");
    assert_eq!(session_summaries.len(), 1);
    assert_eq!(session_summaries[0].context, "updated context");

    let session_states = db.list_session_summaries().expect("session states");
    assert_eq!(session_states.len(), 1);
    assert_eq!(session_states[0].context, "updated context");
}
