use super::controller::{
    RemoteExecutionControllerClient, RemoteExecutionControllerError, binding_error,
};
use super::wire::{RemoteLeaseRenewRequest, RemoteLeaseRenewResponse};
use crate::daemon::db::{AsyncDaemonDb, TaskBoardRemoteMutationOutcome};

impl RemoteExecutionControllerClient {
    pub(crate) async fn reconcile_pending_renewal(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteLeaseRenewRequest,
    ) -> Result<
        (RemoteLeaseRenewResponse, TaskBoardRemoteMutationOutcome),
        RemoteExecutionControllerError,
    > {
        self.preflight_active_lease(db, request, "pending remote renewal is no longer active")
            .await?;
        self.authorize_pending_renewal_replay(db, request).await?;
        let response = self.renew_lease_tolerating_lost_response(request).await?;
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

    async fn authorize_pending_renewal_replay(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteLeaseRenewRequest,
    ) -> Result<(), RemoteExecutionControllerError> {
        let trust = self.current_stable_host_trust_for_replay(db).await?;
        if db
            .require_pending_task_board_remote_renew_replay_authority_fenced(
                request,
                &self.host_id,
                &trust,
            )
            .await?
        {
            Ok(())
        } else {
            Err(binding_error("pending remote renewal authority disappeared").into())
        }
    }
}
