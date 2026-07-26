//! Shared phases of a fenced controller operation.
//!
//! Every mutating controller call runs the same sequence: replay a durable
//! receipt, prove the assignment is still live, claim the fenced I/O authority,
//! then talk to the executor. These helpers hold the phases that more than one
//! operation needs, or that would otherwise bury the sequence in its caller.

use super::controller::{
    RemoteExecutionControllerClient, RemoteExecutionControllerError, binding_error,
    lifecycle_response_may_be_lost, renewal_response_may_be_lost, require_io_authority,
};
use super::wire::{
    RemoteCancelRequest, RemoteCancelResponse, RemoteLeaseRenewRequest, RemoteLeaseRenewResponse,
    RemoteOfferRequest, RemoteOfferResponse,
};
use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteMutationOutcome, TaskBoardRemoteOperationKind,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

impl RemoteExecutionControllerClient {
    /// Returns the durable offer receipt for `request`, or `None` when the
    /// offer has not reached the executor yet.
    pub(super) async fn replay_existing_offer(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteOfferRequest,
    ) -> Result<
        Option<(RemoteOfferResponse, TaskBoardRemoteMutationOutcome)>,
        RemoteExecutionControllerError,
    > {
        let Some(receipt) = db
            .exact_task_board_remote_offer_receipt(request, &self.host_id)
            .await?
        else {
            return Ok(None);
        };
        let record = self.preflight(db, &request.binding.assignment_id).await?;
        Ok(Some((
            receipt.response()?,
            TaskBoardRemoteMutationOutcome::Replayed(record),
        )))
    }

    pub(super) async fn authorize_offer(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteOfferRequest,
    ) -> Result<(), RemoteExecutionControllerError> {
        let trust = self
            .current_operation_trust_for(
                db,
                TaskBoardRemoteOperationKind::Offer,
                &request.binding.assignment_id,
            )
            .await?;
        let authority_at = self.clock.now();
        require_io_authority(
            db.claim_task_board_remote_offer_io_authority_fenced(
                request,
                &self.host_id,
                &authority_at,
                &trust,
            )
            .await?,
            "remote offer lost workflow I/O authority",
        )
    }

    /// Proves the assignment is still durably leased to this client and still
    /// in a state that accepts lease traffic.
    pub(super) async fn preflight_active_lease(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteLeaseRenewRequest,
        inactive_message: &'static str,
    ) -> Result<(), RemoteExecutionControllerError> {
        let record = self
            .preflight_lifecycle(
                db,
                request.binding.assignment_id.as_str(),
                request.lease_id.as_str(),
                request.offer_request_sha256.as_str(),
                &request.binding,
            )
            .await?;
        if matches!(
            record.state,
            TaskBoardRemoteAssignmentState::Claimed
                | TaskBoardRemoteAssignmentState::Started
                | TaskBoardRemoteAssignmentState::Running
        ) {
            Ok(())
        } else {
            Err(binding_error(inactive_message).into())
        }
    }

    pub(super) async fn authorize_renew(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteLeaseRenewRequest,
    ) -> Result<(), RemoteExecutionControllerError> {
        let trust = self
            .current_operation_trust_for(
                db,
                TaskBoardRemoteOperationKind::Renew,
                &request.binding.assignment_id,
            )
            .await?;
        let authority_at = self.clock.now();
        require_io_authority(
            db.claim_task_board_remote_renew_io_authority_fenced(
                request,
                &self.host_id,
                &authority_at,
                &trust,
            )
            .await?,
            "remote lease renewal lost workflow I/O authority",
        )
    }

    pub(super) async fn authorize_cancel(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteCancelRequest,
    ) -> Result<(), RemoteExecutionControllerError> {
        let trust = self
            .current_operation_trust_for(
                db,
                TaskBoardRemoteOperationKind::Cancel,
                &request.binding.assignment_id,
            )
            .await?;
        let authority_at = self.clock.now();
        require_io_authority(
            db.claim_task_board_remote_cancel_io_authority_fenced(
                request,
                &self.host_id,
                &authority_at,
                &trust,
            )
            .await?,
            "remote cancellation lost workflow I/O authority",
        )
    }

    /// Retries a renewal exactly once, because a lost response leaves the
    /// executor-side renewal committed and the second call idempotently
    /// re-reads it.
    pub(super) async fn renew_lease_tolerating_lost_response(
        &self,
        request: &RemoteLeaseRenewRequest,
    ) -> Result<RemoteLeaseRenewResponse, RemoteExecutionControllerError> {
        match self.client.renew_lease(request).await {
            Ok(response) => Ok(response),
            Err(error) if renewal_response_may_be_lost(&error) => {
                self.client.renew_lease(request).await.map_err(Into::into)
            }
            Err(error) => Err(error.into()),
        }
    }

    /// Retries a cancellation exactly once, on the same lost-response
    /// reasoning as [`Self::renew_lease_tolerating_lost_response`].
    pub(super) async fn cancel_tolerating_lost_response(
        &self,
        request: &RemoteCancelRequest,
    ) -> Result<RemoteCancelResponse, RemoteExecutionControllerError> {
        match self.client.cancel(request).await {
            Ok(response) => Ok(response),
            Err(error) if lifecycle_response_may_be_lost(&error) => {
                self.client.cancel(request).await.map_err(Into::into)
            }
            Err(error) => Err(error.into()),
        }
    }
}
