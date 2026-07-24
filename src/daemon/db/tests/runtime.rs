use super::*;
use crate::daemon::protocol::CodexRunEvent;
use serde_json::json;
use tempfile::tempdir;

#[test]
fn codex_runs_round_trip_and_list_newest_first() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    let state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let mut older = sample_codex_run("codex-run-1", "2026-04-09T10:00:00Z");
    older.status = CodexRunStatus::Completed;
    older.task_id = Some("task-1".into());
    older.board_item_id = Some("board-item-1".into());
    older.workflow_execution_id = Some("workflow-1".into());
    older.final_message = Some("Done.".into());
    older.model = Some("gpt-5.5".into());
    older.effort = Some("low".into());
    older.events.push(CodexRunEvent {
        event_id: "codex-run-1-1".into(),
        sequence: 1,
        recorded_at: "2026-04-09T10:00:01Z".into(),
        kind: "turn/completed".into(),
        summary: "Codex turn completed".into(),
        thread_id: Some("thread-1".into()),
        turn_id: Some("turn-1".into()),
        item_id: None,
        payload: json!({"turn": {"status": "completed"}}),
    });
    db.save_codex_run(&older).expect("save older run");

    let newer = sample_codex_run("codex-run-2", "2026-04-09T11:00:00Z");
    db.save_codex_run(&newer).expect("save newer run");

    let runs = db
        .list_codex_runs(&state.session_id)
        .expect("list codex runs");
    assert_eq!(runs.len(), 2);
    assert_eq!(runs[0].run_id, "codex-run-2");
    assert_eq!(runs[1].run_id, "codex-run-1");

    let loaded = db
        .codex_run("codex-run-1")
        .expect("load codex run")
        .expect("present");
    assert_eq!(loaded.status, CodexRunStatus::Completed);
    assert_eq!(loaded.task_id.as_deref(), Some("task-1"));
    assert_eq!(loaded.board_item_id.as_deref(), Some("board-item-1"));
    assert_eq!(loaded.workflow_execution_id.as_deref(), Some("workflow-1"));
    assert_eq!(loaded.final_message.as_deref(), Some("Done."));
    assert_eq!(loaded.session_agent_id.as_deref(), Some("codex-worker"));
    assert_eq!(loaded.model.as_deref(), Some("gpt-5.5"));
    assert_eq!(loaded.effort.as_deref(), Some("low"));
    assert_eq!(loaded.events.len(), 1);
    assert_eq!(loaded.events[0].kind, "turn/completed");
}

#[test]
fn agent_tuis_round_trip_and_list_newest_first() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    let state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let mut older = sample_agent_tui("agent-tui-1", "2026-04-09T10:00:00Z");
    older.status = AgentTuiStatus::Stopped;
    db.save_agent_tui(&older).expect("save older tui");

    let newer = sample_agent_tui("agent-tui-2", "2026-04-09T11:00:00Z");
    db.save_agent_tui(&newer).expect("save newer tui");

    let tuis = db.list_agent_tuis(&state.session_id).expect("list tuis");
    assert_eq!(tuis.len(), 2);
    assert_eq!(tuis[0].tui_id, "agent-tui-2");
    assert_eq!(tuis[1].tui_id, "agent-tui-1");

    let loaded = db
        .agent_tui("agent-tui-1")
        .expect("load tui")
        .expect("present");
    assert_eq!(loaded.status, AgentTuiStatus::Stopped);
    assert_eq!(loaded.screen.text, "ready");
    assert_eq!(loaded.argv, vec!["copilot".to_string()]);
}

#[tokio::test]
async fn async_codex_runs_round_trip_and_list_newest_first() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let db = DaemonDb::open(&db_path).expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    let state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");
    drop(db);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async db");

    let mut older = sample_codex_run("codex-run-1", "2026-04-09T10:00:00Z");
    older.status = CodexRunStatus::Completed;
    older.task_id = Some("task-1".into());
    older.board_item_id = Some("board-item-1".into());
    older.workflow_execution_id = Some("workflow-1".into());
    older.final_message = Some("Done.".into());
    older.model = Some("gpt-5.5".into());
    older.effort = Some("low".into());
    older.events.push(CodexRunEvent {
        event_id: "codex-run-1-1".into(),
        sequence: 1,
        recorded_at: "2026-04-09T10:00:01Z".into(),
        kind: "turn/completed".into(),
        summary: "Codex turn completed".into(),
        thread_id: Some("thread-1".into()),
        turn_id: Some("turn-1".into()),
        item_id: None,
        payload: json!({"turn": {"status": "completed"}}),
    });
    async_db
        .save_codex_run(&older)
        .await
        .expect("save older run");

    let newer = sample_codex_run("codex-run-2", "2026-04-09T11:00:00Z");
    async_db
        .save_codex_run(&newer)
        .await
        .expect("save newer run");

    let runs = async_db
        .list_codex_runs(&state.session_id)
        .await
        .expect("list codex runs");
    assert_eq!(runs.len(), 2);
    assert_eq!(runs[0].run_id, "codex-run-2");
    assert_eq!(runs[1].run_id, "codex-run-1");

    let loaded = async_db
        .codex_run("codex-run-1")
        .await
        .expect("load codex run")
        .expect("present");
    assert_eq!(loaded.status, CodexRunStatus::Completed);
    assert_eq!(loaded.task_id.as_deref(), Some("task-1"));
    assert_eq!(loaded.board_item_id.as_deref(), Some("board-item-1"));
    assert_eq!(loaded.workflow_execution_id.as_deref(), Some("workflow-1"));
    assert_eq!(loaded.final_message.as_deref(), Some("Done."));
    assert_eq!(loaded.session_agent_id.as_deref(), Some("codex-worker"));
    assert_eq!(loaded.model.as_deref(), Some("gpt-5.5"));
    assert_eq!(loaded.effort.as_deref(), Some("low"));
    assert_eq!(loaded.events.len(), 1);
    assert_eq!(loaded.events[0].kind, "turn/completed");
}

/// A standalone triage-escalation run (see
/// `CodexControllerHandle::prepare_standalone_run`) has no owning session at
/// all -- `session_id` on the snapshot is a free-form label, not a real
/// session id. Persisting it must store an honest NULL rather than a value
/// that would violate the `codex_runs.session_id` foreign key, and loading
/// it back must fall back to the run's own id rather than surface a NULL
/// on a wire type that stays non-optional.
#[tokio::test]
async fn async_standalone_codex_run_persists_a_null_session_and_falls_back_on_load() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async db");

    let mut standalone = sample_codex_run(
        "codex-run-standalone-1",
        "2026-04-09T10:00:00Z",
    );
    standalone.session_id = "triage-escalation-no-such-session".into();
    standalone.session_agent_id = None;
    async_db
        .save_codex_run(&standalone)
        .await
        .expect("save standalone run despite no matching session");

    let stored_session_id: Option<String> = sqlx::query_scalar(
        "SELECT session_id FROM codex_runs WHERE run_id = 'codex-run-standalone-1'",
    )
    .fetch_one(async_db.pool())
    .await
    .expect("load raw session_id column");
    assert_eq!(
        stored_session_id, None,
        "a session-less run must persist NULL, not the free-form label"
    );

    let loaded = async_db
        .codex_run("codex-run-standalone-1")
        .await
        .expect("load standalone run")
        .expect("present");
    assert_eq!(
        loaded.session_id, "codex-run-standalone-1",
        "the wire snapshot falls back to the run's own id, never surfacing NULL"
    );
}

#[tokio::test]
async fn async_agent_tuis_round_trip_and_list_newest_first() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let db = DaemonDb::open(&db_path).expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    let state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");
    drop(db);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async db");

    let mut older = sample_agent_tui("agent-tui-1", "2026-04-09T10:00:00Z");
    older.status = AgentTuiStatus::Stopped;
    async_db
        .save_agent_tui(&older)
        .await
        .expect("save older tui");

    let newer = sample_agent_tui("agent-tui-2", "2026-04-09T11:00:00Z");
    async_db
        .save_agent_tui(&newer)
        .await
        .expect("save newer tui");

    let tuis = async_db
        .list_agent_tuis(&state.session_id)
        .await
        .expect("list tuis");
    assert_eq!(tuis.len(), 2);
    assert_eq!(tuis[0].tui_id, "agent-tui-2");
    assert_eq!(tuis[1].tui_id, "agent-tui-1");

    let loaded = async_db
        .agent_tui("agent-tui-1")
        .await
        .expect("load tui")
        .expect("present");
    assert_eq!(loaded.status, AgentTuiStatus::Stopped);
    assert_eq!(loaded.screen.text, "ready");
    assert_eq!(loaded.argv, vec!["copilot".to_string()]);

    let refresh_state = async_db
        .agent_tui_live_refresh_state("agent-tui-2")
        .await
        .expect("load live refresh state")
        .expect("refresh state present");
    assert_eq!(refresh_state.status, AgentTuiStatus::Running);
}
