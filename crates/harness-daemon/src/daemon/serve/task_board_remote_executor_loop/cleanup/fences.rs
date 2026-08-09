use super::concurrent;
use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db::{TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorStartAuthority};
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::task_board::TaskBoardRemoteAssignmentState;
use crate::task_board::remote_wire::wire::RemoteSettledRequest;
use harness_daemon_db_queries::AsyncAgentWorkingCopyQueries;
use harness_kernel::errors::CliError;

use super::super::RemoteWorkerIdentity;

pub(super) fn exact_unstarted_provisioning(
    record: &TaskBoardRemoteAssignmentRecord,
    authority: &TaskBoardRemoteExecutorStartAuthority,
) -> bool {
    record.state == TaskBoardRemoteAssignmentState::Claimed
        && record.fencing_epoch == authority.fencing_epoch
        && record.executor_start_authority_sha256.as_deref() == Some(authority.sha256.as_str())
        && record.executor_start_authority_at.as_deref() == Some(authority.acquired_at.as_str())
        && record.start_receipt.is_none()
        && record.started_at.is_none()
        && record.workspace_ref.is_none()
        && record.executor_lifecycle_owner.is_none()
        && record.executor_stop_pending.is_none()
}

pub(super) async fn preclaim_superseded_cleanup_is_empty(
    db: &AsyncDaemonDbHandle,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
) -> Result<bool, CliError> {
    if record.state != TaskBoardRemoteAssignmentState::Superseded {
        return Ok(false);
    }
    let exact = record.claimed_at.is_none()
        && record.started_at.is_none()
        && record.workspace_ref.is_none()
        && record.claim_receipt.is_none()
        && record.start_receipt.is_none()
        && record.executor_start_authority_sha256.is_none()
        && record.executor_lifecycle_owner.is_none()
        && record.executor_stop_pending.is_none()
        && record.status_response.is_none()
        && record.status_sha256.is_none()
        && record.result_sha256.is_none();
    if !exact {
        return Err(concurrent(
            "preclaim superseded cleanup contains executor work evidence",
        ));
    }
    let offer = record.require_offer()?;
    if db
        .task_board_remote_executor_run(offer, &identity.run_id)
        .await?
        .is_some()
        || if offer.work_owner.is_some() {
            db.load_agent_working_copy(&identity.working_copy_id)
                .await?
                .is_some()
        } else {
            db.resolve_session(&identity.session_id).await?.is_some()
        }
    {
        return Err(concurrent(
            "preclaim superseded cleanup found unexpected executor state",
        ));
    }
    Ok(true)
}

pub(super) fn require_exact_cleanup_generation(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteSettledRequest,
) -> Result<(), CliError> {
    let offer = record.require_offer()?;
    if request.binding != offer.binding
        || request.offer_request_sha256 != offer.request_sha256
        || request.lease_id != record.lease_id.as_deref().unwrap_or_default()
    {
        return Err(concurrent(
            "remote executor cleanup receipt belongs to another assignment generation",
        ));
    }
    Ok(())
}
