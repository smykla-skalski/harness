use super::*;

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
    older.final_message = Some("Done.".into());
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
    assert_eq!(loaded.final_message.as_deref(), Some("Done."));
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
