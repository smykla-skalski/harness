use super::controller::{
    RemoteExecutionControllerClient, RemoteExecutionControllerError, binding_error,
    renewal_response_may_be_lost,
};
use super::wire::{RemoteLeaseRenewRequest, RemoteLeaseRenewResponse};
use crate::daemon::db::{AsyncDaemonDb, TaskBoardRemoteMutationOutcome};
use crate::task_board::TaskBoardRemoteAssignmentState;

impl RemoteExecutionControllerClient {
    pub(crate) async fn reconcile_pending_renewal(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteLeaseRenewRequest,
    ) -> Result<
        (RemoteLeaseRenewResponse, TaskBoardRemoteMutationOutcome),
        RemoteExecutionControllerError,
    > {
        let record = self
            .preflight_lifecycle(
                db,
                request.binding.assignment_id.as_str(),
                request.lease_id.as_str(),
                request.offer_request_sha256.as_str(),
                &request.binding,
            )
            .await?;
        if !matches!(
            record.state,
            TaskBoardRemoteAssignmentState::Claimed
                | TaskBoardRemoteAssignmentState::Started
                | TaskBoardRemoteAssignmentState::Running
        ) {
            return Err(binding_error("pending remote renewal is no longer active").into());
        }
        let trust = self.current_stable_host_trust_for_replay(db).await?;
        if !db
            .require_pending_task_board_remote_renew_replay_authority_fenced(
                request,
                &self.host_id,
                &trust,
            )
            .await?
        {
            return Err(binding_error("pending remote renewal authority disappeared").into());
        }
        let response = match self.client.renew_lease(request).await {
            Ok(response) => response,
            Err(error) if renewal_response_may_be_lost(&error) => {
                self.client.renew_lease(request).await?
            }
            Err(error) => return Err(error.into()),
        };
        let settled_at = self.clock.now();
        let trust = self.current_stable_host_trust_for_replay(db).await?;
        let outcome = Box::pin(
            db.record_pending_task_board_remote_assignment_lease_renewal_replay(
                request,
                &response,
                &self.host_id,
                &settled_at,
                &trust,
            ),
        )
        .await?;
        Ok((response, outcome))
    }
}
