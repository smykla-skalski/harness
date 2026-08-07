//! Who a dispatched worker belongs to, and what has to be undone when its
//! dispatch is compensated.
//!
//! A fresh dispatch owns a workspace and a checkout; a board item linked to a
//! Session before workspaces existed owns neither. Everything here reads the
//! owner the dispatch actually has rather than assuming one of the two.

use std::path::PathBuf;

use tokio::task::spawn_blocking;

use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::service::workspace_checkout;
use crate::task_board::{AgentMode, DispatchAppliedTask};
use harness_daemon_db_queries::{
    AsyncAgentWorkingCopyQueries, WorkspaceManagedAgentKind, WorkspaceMemberRegistration,
};
use harness_kernel::errors::CliError;

use super::DISPATCH_WORKER_RUNTIME;

/// Record the started worker as a member of its workspace team.
///
/// The daemon started this process, so it registers the membership itself
/// rather than waiting for the agent to announce itself the way a Session
/// auto-join does. Idempotent on the managed identity, so a reclaimed start
/// updates the existing member instead of adding a second one.
pub(super) async fn join_worker_to_workspace(
    db: &AsyncDaemonDbHandle,
    applied: &DispatchAppliedTask,
    worker_id: &str,
) -> Result<(), CliError> {
    let Some(workspace_id) = applied.workspace_id.clone() else {
        return Ok(());
    };
    db.register_workspace_managed_member(&WorkspaceMemberRegistration {
        workspace_id,
        kind: worker_managed_kind(applied),
        managed_agent_id: worker_id.to_string(),
        // Both dispatch modes run Codex today - the terminal one through a PTY,
        // the headless one through the controller - so the runtime family is the
        // same and only the managed kind above tells them apart.
        runtime_kind: DISPATCH_WORKER_RUNTIME.to_string(),
        display_name: format!("Task Board: {}", applied.item.title),
        assignment_id: Some(applied.work_item_id.clone()),
    })
    .await
    .map(|_| ())
}

/// Undo what a compensated dispatch created: the member's runtime is recorded
/// as stopped, and its checkout is released and removed.
///
/// The membership row itself stays. Runtime stop and membership removal are
/// separate results, and a worker that ran and was compensated is history worth
/// keeping rather than a row to erase.
pub(crate) async fn settle_compensated_workspace_worker(
    db: &AsyncDaemonDbHandle,
    applied: &DispatchAppliedTask,
    worker_id: &str,
    reason: &str,
) {
    if let Some(workspace_id) = applied.workspace_id.as_deref() {
        let member_id = WorkspaceMemberRegistration {
            workspace_id: workspace_id.to_string(),
            kind: worker_managed_kind(applied),
            managed_agent_id: worker_id.to_string(),
            runtime_kind: DISPATCH_WORKER_RUNTIME.to_string(),
            display_name: String::new(),
            assignment_id: None,
        }
        .member_id();
        if let Err(error) = db
            .record_workspace_member_runtime_stop(workspace_id, &member_id, reason)
            .await
        {
            tracing::warn!(
                board_item_id = %applied.board_item_id,
                worker_id,
                %error,
                "compensated dispatch left its workspace member reading as running"
            );
        }
    }
    release_worker_workspace_checkout(db, applied, reason).await;
}

const fn worker_managed_kind(applied: &DispatchAppliedTask) -> WorkspaceManagedAgentKind {
    if matches!(applied.item.agent_mode, AgentMode::Interactive) {
        WorkspaceManagedAgentKind::Terminal
    } else {
        WorkspaceManagedAgentKind::Codex
    }
}

/// Return a failed dispatch's checkout to the pool and remove it from disk.
///
/// Best effort by design: compensation has already stopped the runtime and
/// finalized the claim, and a checkout that cannot be released is a leaked
/// directory rather than a reason to fail the compensation that just succeeded.
///
/// The row is released first and only once - `release_agent_working_copy`
/// reports whether this call was the one that claimed the cleanup - so two
/// racing compensations cannot both start removing the same worktree.
pub(super) async fn release_worker_workspace_checkout(
    db: &AsyncDaemonDbHandle,
    applied: &DispatchAppliedTask,
    reason: &str,
) {
    let Some(working_copy_id) = applied.working_copy_id.as_deref() else {
        return;
    };
    let recorded = match db.load_agent_working_copy(working_copy_id).await {
        Ok(recorded) => recorded,
        Err(error) => {
            warn_checkout_cleanup(&applied.board_item_id, working_copy_id, &error);
            return;
        }
    };
    match db.release_agent_working_copy(working_copy_id, reason).await {
        Ok(true) => {}
        Ok(false) => return,
        Err(error) => {
            warn_checkout_cleanup(&applied.board_item_id, working_copy_id, &error);
            return;
        }
    }
    let Some(recorded) = recorded else {
        return;
    };
    let layout = workspace_checkout::recorded_layout(&recorded.project_name, working_copy_id);
    let origin = PathBuf::from(recorded.origin_path);
    let _ = spawn_blocking(move || {
        workspace_checkout::discard_workspace_checkout(&origin, &layout);
    })
    .await;
}

fn warn_checkout_cleanup(board_item_id: &str, working_copy_id: &str, error: &CliError) {
    tracing::warn!(
        board_item_id,
        working_copy_id,
        %error,
        "compensated dispatch left its working copy recorded as live"
    );
}

/// The lane a worker's start and compensation serialize on. Keyed by whichever
/// owner the dispatch actually has, so two dispatches in one workspace still
/// contend and a legacy dispatch keeps contending on its Session.
pub(super) fn worker_lock_owner(applied: &DispatchAppliedTask) -> String {
    applied
        .workspace_id
        .clone()
        .or_else(|| applied.session_id.clone())
        .unwrap_or_else(|| applied.board_item_id.clone())
}

/// Owner identities a reclaimed worker may legitimately report.
///
/// A workspace-owned Codex run names itself, because `start_standalone_run_with_id`
/// has no owner to name and stamps the run id where a session id would go; the
/// terminal names its workspace. A legacy dispatch accepts only its Session.
pub(super) fn applied_worker_owner(applied: &DispatchAppliedTask, worker_id: &str) -> Vec<String> {
    let mut owners = Vec::new();
    if let Some(workspace_id) = applied.workspace_id.clone() {
        owners.push(workspace_id);
        owners.push(worker_id.to_string());
    }
    if let Some(session_id) = applied.session_id.clone() {
        owners.push(session_id);
    }
    owners
}

