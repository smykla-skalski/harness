//! Provision the durable owner of a fresh task-board dispatch.
//!
//! Replaces the Session, worktree, and Session task the old preparation path
//! created with a workspace, a working copy, and nothing else. The board item
//! and its workflow execution are the work record; there is no Session row and
//! no Session task behind a worker started this way.

use tokio::task::spawn_blocking;

use crate::daemon::db::ClaimedTaskBoardDispatchPreparation;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::service::workspace_checkout::{
    PreparedWorkspaceCheckout, WorkspaceCheckoutPlan, discard_workspace_checkout,
    prepare_workspace_checkout,
};
use crate::daemon::state;
use crate::task_board::DispatchFailureKind;
use harness_daemon_db_queries::AsyncAgentWorkingCopyQueries;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::DispatchOwner;

pub(super) async fn prepare_workspace_owner(
    db: &AsyncDaemonDbHandle,
    claim: &ClaimedTaskBoardDispatchPreparation,
) -> Result<DispatchOwner, (DispatchFailureKind, CliError)> {
    let preparation = &claim.preparation;
    let working_copy_id = preparation.working_copy_id.clone().ok_or_else(|| {
        (
            DispatchFailureKind::CreateSession,
            CliError::from(CliErrorKind::workflow_io(
                "task-board dispatch preparation reserved neither a Session nor a working copy",
            )),
        )
    })?;
    let project_dir = preparation.project_dir.clone().ok_or_else(|| {
        (
            DispatchFailureKind::CreateSession,
            CliError::from(CliErrorKind::workflow_io(
                "task-board dispatch preparation has no project_dir",
            )),
        )
    })?;
    let plan = WorkspaceCheckoutPlan {
        daemon_id: daemon_id().await?,
        working_copy_id,
        project_dir,
        base_ref: None,
    };
    let prepared = spawn_blocking(move || prepare_workspace_checkout(&plan))
        .await
        .map_err(|error| {
            (
                DispatchFailureKind::CreateSession,
                CliError::from(CliErrorKind::workflow_io(format!(
                    "join dispatch checkout worker: {error}"
                ))),
            )
        })?
        .map_err(|error| (DispatchFailureKind::CreateSession, error))?;

    // The checkout is on disk before this row exists, so a failure here would
    // otherwise strand a worktree nothing points at. Discard it and report the
    // failure, which keeps the retry from stacking a second checkout beside it.
    let branch = prepared.request.branch_ref.clone();
    let worktree = prepared.request.worktree_path.clone();
    match db.provision_agent_workspace_checkout(&prepared.request).await {
        Ok(provisioned) => Ok(DispatchOwner {
            branch,
            worktree,
            workspace_id: Some(provisioned.workspace_id.clone()),
            launch_owner_id: provisioned.workspace_id,
        }),
        Err(error) => {
            discard_prepared_checkout(prepared).await;
            Err((DispatchFailureKind::CreateSession, error))
        }
    }
}

/// A workspace is keyed per daemon, so a dispatch that could not name its
/// daemon cannot pick the right one and must refuse rather than guess.
async fn daemon_id() -> Result<String, (DispatchFailureKind, CliError)> {
    let identity = spawn_blocking(state::reported_daemon_identity)
        .await
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "join daemon identity read: {error}"
            )))
        })
        .and_then(|identity| identity)
        .map_err(|error| (DispatchFailureKind::CreateSession, error))?;
    identity.map(|identity| identity.daemon_id).ok_or_else(|| {
        (
            DispatchFailureKind::CreateSession,
            CliError::from(CliErrorKind::workflow_io("daemon identity is unavailable")),
        )
    })
}

async fn discard_prepared_checkout(prepared: PreparedWorkspaceCheckout) {
    let _ = spawn_blocking(move || {
        discard_workspace_checkout(&prepared.canonical_origin, &prepared.layout);
    })
    .await;
}
