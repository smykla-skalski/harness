use serde_json::Value;

use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::CodexRunSnapshot;
use crate::daemon::service;

use super::task_board_support::required_string;

/// Assert the dispatch started a Codex worker, and return its managed run id.
///
/// The run is reached through whichever owner the dispatch landed under. A
/// legacy dispatch lists its runs by Session. A workspace-owned run has no
/// Session and names itself, so the way back to it is the workspace team
/// membership its start recorded.
pub(super) async fn assert_codex_worker_started(
    state: &DaemonHttpState,
    applied: &Value,
    board_item_id: &str,
) -> String {
    let work_item_id = required_string(applied, "work_item_id");
    let run = match applied.get("session_id").and_then(Value::as_str) {
        Some(session_id) => session_worker_run(state, session_id, board_item_id, &work_item_id),
        None => workspace_worker_run(state, &required_string(applied, "workspace_id")).await,
    };
    assert!(
        run.prompt.contains(&format!("Board item: {board_item_id}")),
        "the worker prompt names its board item"
    );
    assert!(
        run.prompt
            .contains(&format!("Session task: {work_item_id}")),
        "the worker prompt names its work item"
    );
    assert!(
        run.display_name
            .as_deref()
            .is_some_and(|name| { name.starts_with("Task Board: ") })
    );
    run.run_id
}

fn session_worker_run(
    state: &DaemonHttpState,
    session_id: &str,
    board_item_id: &str,
    work_item_id: &str,
) -> CodexRunSnapshot {
    let run = state
        .codex_controller
        .list_runs(session_id)
        .expect("list codex runs")
        .runs
        .into_iter()
        .find(|run| {
            run.prompt.contains(&format!("Board item: {board_item_id}"))
                && run
                    .prompt
                    .contains(&format!("Session task: {work_item_id}"))
        })
        .expect("task-board codex worker run");
    assert_eq!(run.session_id, session_id);
    run
}

async fn workspace_worker_run(state: &DaemonHttpState, workspace_id: &str) -> CodexRunSnapshot {
    let run_id = workspace_managed_worker_id(state, workspace_id).await;
    let run = state
        .codex_controller
        .run(&run_id)
        .expect("load the workspace codex run");
    assert_eq!(
        run.session_id, run.run_id,
        "a workspace-owned run stands in for its own session id"
    );
    run
}

/// The managed worker the workspace team joined at start.
pub(super) async fn workspace_managed_worker_id(
    state: &DaemonHttpState,
    workspace_id: &str,
) -> String {
    let async_db = state.async_db.get().expect("async db");
    let team = service::get_agent_workspace_team_async(async_db, workspace_id)
        .await
        .expect("load the workspace team")
        .team
        .expect("a started worker has a workspace team");
    team.members
        .iter()
        .find_map(|member| {
            member
                .managed_identity
                .as_ref()
                .map(|identity| identity.managed_agent_id.clone())
        })
        .expect("the workspace team names its managed worker")
}

/// Assert no worker has joined the workspace team yet.
pub(super) async fn assert_no_workspace_worker(state: &DaemonHttpState, workspace_id: &str) {
    let async_db = state.async_db.get().expect("async db");
    let team = service::get_agent_workspace_team_async(async_db, workspace_id)
        .await
        .expect("load the workspace team")
        .team;
    let members = team.map(|team| team.members.len()).unwrap_or_default();
    assert_eq!(members, 0, "a held dispatch starts no worker");
}
