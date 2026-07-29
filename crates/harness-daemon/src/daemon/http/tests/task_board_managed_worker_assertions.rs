pub(super) fn assert_codex_worker_started(
    state: &crate::daemon::http::DaemonHttpState,
    session_id: &str,
    board_item_id: &str,
    work_item_id: &str,
) -> String {
    let runs = state
        .codex_controller
        .list_runs(session_id)
        .expect("list codex runs")
        .runs;
    let run = runs
        .iter()
        .find(|run| {
            run.prompt.contains(&format!("Board item: {board_item_id}"))
                && run
                    .prompt
                    .contains(&format!("Session task: {work_item_id}"))
        })
        .expect("task-board codex worker run");
    assert_eq!(run.session_id, session_id);
    assert!(
        run.display_name
            .as_deref()
            .is_some_and(|name| { name.starts_with("Task Board: ") })
    );
    run.run_id.clone()
}
