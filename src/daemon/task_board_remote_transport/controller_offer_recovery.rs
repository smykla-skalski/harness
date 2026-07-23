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
        if let Some(receipt) = db
            .exact_task_board_remote_offer_receipt(request, &self.host_id)
            .await?
        {
            let response = receipt.response()?;
            return match response.disposition {
                RemoteOfferDisposition::Accepted => {
                    let record = self.preflight(db, &request.binding.assignment_id).await?;
                    Ok(RemotePredecessorOfferRecoveryOutcome::Accepted {
                        outcome: Box::new(TaskBoardRemoteMutationOutcome::Replayed(record)),
                    })
                }
                RemoteOfferDisposition::Rejected => Ok(
                    RemotePredecessorOfferRecoveryOutcome::Rejected(Box::new(response)),
                ),
            };
        }
        let current = self.current_source_recovery_trust(db).await?;
        if current != *trust {
            return Err(binding_error(
                "remote host trust changed during predecessor offer recovery",
            )
            .into());
        }
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
