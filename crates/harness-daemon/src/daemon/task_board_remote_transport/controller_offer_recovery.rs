use super::controller::{
    RemoteExecutionControllerClient, RemoteExecutionControllerError, binding_error,
};
use super::wire::{RemoteOfferDisposition, RemoteOfferRequest, RemoteOfferResponse};
use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteMutationOutcome, TaskBoardRemoteOperationTrustFence,
};

#[derive(Debug)]
pub(crate) enum RemotePredecessorOfferRecoveryOutcome {
    Accepted {
        outcome: Box<TaskBoardRemoteMutationOutcome>,
    },
    Rejected(Box<RemoteOfferResponse>),
}

impl RemoteExecutionControllerClient {
    pub(crate) async fn recover_predecessor_offer(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteOfferRequest,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<RemotePredecessorOfferRecoveryOutcome, RemoteExecutionControllerError> {
        if request.binding.host_instance_id == trust.observed_host_instance_id {
            return Err(binding_error(
                "predecessor offer recovery requires a successor executor instance",
            )
            .into());
        }
        if let Some(replayed) = self.replay_recovered_offer_receipt(db, request).await? {
            return Ok(replayed);
        }
        let current = self.current_source_recovery_trust(db).await?;
        if current != *trust {
            return Err(binding_error(
                "remote host trust changed during predecessor offer recovery",
            )
            .into());
        }
        self.place_recovered_offer(db, request, trust).await
    }

    /// Returns the durable receipt for an already-delivered recovery offer, or
    /// `None` when the successor instance has never seen this offer.
    async fn replay_recovered_offer_receipt(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteOfferRequest,
    ) -> Result<Option<RemotePredecessorOfferRecoveryOutcome>, RemoteExecutionControllerError> {
        let Some(receipt) = db
            .exact_task_board_remote_offer_receipt(request, &self.host_id)
            .await?
        else {
            return Ok(None);
        };
        let response = receipt.response()?;
        match response.disposition {
            RemoteOfferDisposition::Accepted => {
                let record = self.preflight(db, &request.binding.assignment_id).await?;
                Ok(Some(RemotePredecessorOfferRecoveryOutcome::Accepted {
                    outcome: Box::new(TaskBoardRemoteMutationOutcome::Replayed(record)),
                }))
            }
            RemoteOfferDisposition::Rejected => Ok(Some(
                RemotePredecessorOfferRecoveryOutcome::Rejected(Box::new(response)),
            )),
        }
    }

    async fn place_recovered_offer(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteOfferRequest,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<RemotePredecessorOfferRecoveryOutcome, RemoteExecutionControllerError> {
        let response = self.client.offer(request).await?;
        match response.disposition {
            RemoteOfferDisposition::Accepted => {
                let observed_at = self.clock.now();
                let outcome = Box::pin(db.record_task_board_remote_predecessor_offer_acceptance(
                    &response,
                    &self.host_id,
                    trust,
                    &observed_at,
                ))
                .await?;
                Ok(RemotePredecessorOfferRecoveryOutcome::Accepted {
                    outcome: Box::new(outcome),
                })
            }
            RemoteOfferDisposition::Rejected => Ok(
                RemotePredecessorOfferRecoveryOutcome::Rejected(Box::new(response)),
            ),
        }
    }
}
