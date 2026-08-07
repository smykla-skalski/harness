//! Launch one dispatched worker in whichever runtime and owner it has.

use crate::daemon::agent_tui::WorkspaceTerminalOwner;
use crate::daemon::http::{
    DaemonHttpState, run_codex_agent_blocking, run_terminal_agent_blocking,
};
use crate::daemon::protocol::ManagedAgentSnapshot;
use crate::task_board::{DispatchAppliedTask, codex_worker_id, terminal_worker_id};
use harness_kernel::errors::{CliError, CliErrorKind};

use super::requests::{codex_worker_request, terminal_worker_request};

pub(super) async fn start_codex_worker(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    let run_id = codex_worker_id(dispatch_intent_id);
    let request = codex_worker_request(applied, &run_id)?;
    if applied.workspace_id.is_some() {
        // No owning Session, so the run identifies itself: `start_standalone_run_with_id`
        // stamps the run id where a session id would go and takes the checkout
        // directly, which is exactly what a workspace-owned worker has.
        let project_dir = worker_checkout(applied)?;
        return run_codex_agent_blocking(state, "task-board worker start", move |controller| {
            controller
                .start_standalone_run_with_id(&project_dir, &request, run_id)
                .map(ManagedAgentSnapshot::Codex)
        })
        .await;
    }
    let session_id = legacy_session_id(applied)?;
    run_codex_agent_blocking(state, "task-board worker start", move |controller| {
        controller
            .start_run_with_id(&session_id, &request, run_id)
            .map(ManagedAgentSnapshot::Codex)
    })
    .await
}

pub(super) async fn start_interactive_worker(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    let tui_id = terminal_worker_id(dispatch_intent_id);
    let request = terminal_worker_request(applied, &tui_id)?;
    if let Some(workspace_id) = applied.workspace_id.clone() {
        let project_dir = worker_checkout(applied)?;
        return run_terminal_agent_blocking(state, "task-board worker start", move |manager| {
            manager
                .start_in_workspace_with_id(
                    &WorkspaceTerminalOwner {
                        workspace_id: &workspace_id,
                        project_dir: &project_dir,
                    },
                    &request,
                    tui_id,
                )
                .map(ManagedAgentSnapshot::Terminal)
        })
        .await;
    }
    let session_id = legacy_session_id(applied)?;
    run_terminal_agent_blocking(state, "task-board worker start", move |manager| {
        manager
            .start_with_id(&session_id, &request, tui_id)
            .map(ManagedAgentSnapshot::Terminal)
    })
    .await
}

/// The checkout a workspace-owned worker runs in. Completion writes it onto the
/// ticket, so an applied task missing it never had a working copy and must not
/// be started against whatever directory the daemon happens to be in.
fn worker_checkout(applied: &DispatchAppliedTask) -> Result<String, CliError> {
    applied.item.workflow.worktree.clone().ok_or_else(|| {
        CliErrorKind::workflow_io(format!(
            "task-board item '{}' has no working copy to start its worker in",
            applied.board_item_id
        ))
        .into()
    })
}

fn legacy_session_id(applied: &DispatchAppliedTask) -> Result<String, CliError> {
    applied.session_id.clone().ok_or_else(|| {
        CliErrorKind::workflow_io(format!(
            "task-board dispatch for item '{}' has neither a workspace nor a Session owner",
            applied.board_item_id
        ))
        .into()
    })
}

