//! The one path that may provision a workspace and issue a Start for a remote
//! worker. It is reached only when the record carries no durable start-IO
//! permit and no run evidence, so every other caller recovers instead.
//!
//! Each `Ok(None)` below means "abandon this pass and let the next scan retry",
//! not an error: shutdown arrived, another host holds the claim, the start
//! window closed, or the authority was revoked between steps.

use tokio::sync::watch;

use super::{
    PreparedRemoteWorker, PreparedRemoteWorkerAction, RemoteOfferRequest, RemoteWorkerAction,
    RemoteWorkerIdentity, TaskBoardRemoteExecutorStartIoPermitOutcome,
    abandon_predecessor_claim, authorize_or_cleanup_remote_provisioning,
    claim_or_cleanup_remote_start_io, cleanup_predecessor_remote_start, executor_start_authority,
    prepare_remote_workspace, shutdown_observed, start_authority_for_action, start_window_is_open,
    utc_now,
};
use crate::daemon::db::{AsyncDaemonDb, TaskBoardRemoteAssignmentRecord};
use crate::errors::CliError;

pub(super) async fn prepare_fresh_remote_worker_start(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    action: RemoteWorkerAction,
    daemon_epoch: &str,
    shutdown_rx: Option<&watch::Receiver<bool>>,
) -> Result<Option<PreparedRemoteWorker>, CliError> {
    if shutdown_observed(shutdown_rx) {
        return Ok(None);
    }
    let persisted_authority = executor_start_authority(record)?;
    if abandon_predecessor_claim(db, record, identity, daemon_epoch).await? {
        return Ok(None);
    }
    // Wall-clock gates fresh claims; authorized generations still reconcile after expiry.
    if persisted_authority.is_none()
        && !start_window_is_open(
            record.lease_expires_at.as_deref().unwrap_or_default(),
            record.deadline_at.as_deref().unwrap_or_default(),
            &utc_now(),
        )?
    {
        return Ok(None);
    }
    let Some(authority) = start_authority_for_action(
        db,
        record,
        identity,
        action,
        persisted_authority,
        daemon_epoch,
    )
    .await?
    else {
        return Ok(None);
    };
    if shutdown_observed(shutdown_rx) {
        return Ok(None);
    }
    if record.claimed_host_instance_id.as_deref() != Some(daemon_epoch) {
        cleanup_predecessor_remote_start(db, Some(&authority), daemon_epoch).await?;
        return Ok(None);
    }
    let Some(authority) = authorize_or_cleanup_remote_provisioning(db, Some(&authority)).await?
    else {
        return Ok(None);
    };
    if shutdown_observed(shutdown_rx) {
        return Ok(None);
    }
    let workspace = match prepare_remote_workspace(db, record, offer, identity, true).await {
        Ok(workspace) => workspace,
        Err(error) => {
            if authorize_or_cleanup_remote_provisioning(db, Some(&authority))
                .await?
                .is_none()
            {
                return Ok(None);
            }
            return Err(error);
        }
    };
    if shutdown_observed(shutdown_rx) {
        return Ok(None);
    }
    match claim_or_cleanup_remote_start_io(db, Some(&authority), &workspace).await? {
        TaskBoardRemoteExecutorStartIoPermitOutcome::Acquired(permit) => {
            Ok(Some(PreparedRemoteWorker {
                workspace,
                action: PreparedRemoteWorkerAction::Start(permit),
            }))
        }
        TaskBoardRemoteExecutorStartIoPermitOutcome::Replayed(_)
        | TaskBoardRemoteExecutorStartIoPermitOutcome::Stale => Ok(None),
    }
}
