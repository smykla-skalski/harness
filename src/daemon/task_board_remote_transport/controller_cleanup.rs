//! Controller-side authenticated cleanup observation and durable adoption.

use super::controller::{RemoteExecutionControllerClient, RemoteExecutionControllerError};
use super::wire_cleanup::{RemoteCleanupObservationRequest, RemoteCleanupObservationResponse};
use crate::daemon::db::{AsyncDaemonDb, TaskBoardRemoteMutationOutcome};

impl RemoteExecutionControllerClient {
    pub(crate) async fn observe_cleanup(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteCleanupObservationRequest,
    ) -> Result<
        Option<(
            RemoteCleanupObservationResponse,
            TaskBoardRemoteMutationOutcome,
        )>,
        RemoteExecutionControllerError,
    > {
        let trust = self.current_configured_host_trust_for_lifecycle(db).await?;
        if let Some(response) = db
            .claim_task_board_remote_cleanup_observation_fenced(request, &self.host_id, &trust)
            .await?
        {
            let record = self.preflight(db, &request.binding.assignment_id).await?;
            return Ok(Some((
                response,
                TaskBoardRemoteMutationOutcome::Replayed(record),
            )));
        }
        let Some(response) = self.client.observe_cleanup(request).await? else {
            return Ok(None);
        };
        let outcome = db
            .record_task_board_remote_cleanup_observation(request, &response, &self.host_id, &trust)
            .await?;
        Ok(Some((response, outcome)))
    }
}
