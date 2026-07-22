use super::controller::{
    RemoteExecutionControllerClient, RemoteExecutionControllerError, binding_error,
};
use super::wire::{RemoteSourceBundleUploadRequest, RemoteSourceBundleUploadResponse};
use crate::daemon::db::{AsyncDaemonDb, TaskBoardRemoteOperationTrustFence};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RemoteSourceBundleRecoveryOutcome {
    CurrentGeneration,
    Receipt {
        response: RemoteSourceBundleUploadResponse,
        trust: TaskBoardRemoteOperationTrustFence,
    },
    Abandoned {
        request: super::wire::RemoteSourceBundleAbandonRequest,
        response: super::wire::RemoteSourceBundleAbandonResponse,
        trust: TaskBoardRemoteOperationTrustFence,
    },
}

impl RemoteExecutionControllerClient {
    pub(crate) async fn upload_source_bundle(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteSourceBundleUploadRequest,
    ) -> Result<RemoteSourceBundleUploadResponse, RemoteExecutionControllerError> {
        if let Some(stored) = db
            .exact_task_board_remote_source_bundle_upload_receipt(request, &self.host_id)
            .await?
        {
            return Ok(stored.response);
        }
        let trust = self.current_operation_trust(db).await?;
        if !db
            .claim_task_board_remote_source_bundle_upload_io_authority_fenced(
                request,
                &self.host_id,
                &trust,
            )
            .await?
        {
            return Err(binding_error("remote source upload lost its I/O authority").into());
        }
        let response = self.client.upload_source_bundle(request).await?;
        let stored = db
            .record_task_board_remote_source_bundle_upload_response(
                request,
                &response,
                &self.host_id,
            )
            .await?;
        Ok(stored.response)
    }

    pub(crate) async fn verify_or_abandon_predecessor_source_bundle(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteSourceBundleUploadRequest,
    ) -> Result<RemoteSourceBundleRecoveryOutcome, RemoteExecutionControllerError> {
        let trust = self.current_source_recovery_trust(db).await?;
        if request.offer.binding.host_instance_id == trust.observed_host_instance_id {
            return Ok(RemoteSourceBundleRecoveryOutcome::CurrentGeneration);
        }
        if let Some(stored) = db
            .exact_task_board_remote_source_bundle_abandonment(request, &self.host_id)
            .await?
        {
            return Ok(RemoteSourceBundleRecoveryOutcome::Abandoned {
                request: stored.request,
                response: stored.response,
                trust,
            });
        }
        if let Some(stored) = db
            .exact_task_board_remote_source_bundle_upload_receipt(request, &self.host_id)
            .await?
        {
            return Ok(RemoteSourceBundleRecoveryOutcome::Receipt {
                response: stored.response,
                trust,
            });
        }
        let verification = self.client.verify_source_bundle_receipt(request).await?;
        if verification.receipt.is_some() {
            let stored = Box::pin(db.adopt_verified_task_board_remote_source_bundle_receipt(
                request,
                &verification,
                &self.host_id,
                &trust,
            ))
            .await?
            .ok_or_else(|| binding_error("verified source receipt disappeared during adoption"))?;
            return Ok(RemoteSourceBundleRecoveryOutcome::Receipt {
                response: stored.response,
                trust,
            });
        }
        let abandon = super::wire::RemoteSourceBundleAbandonRequest::seal(request, verification)
            .map_err(super::client::RemoteExecutionHttpError::from)?;
        let response = self.client.abandon_source_bundle(&abandon).await?;
        let stored = Box::pin(db.record_task_board_remote_source_bundle_abandonment(
            &abandon,
            &response,
            &self.host_id,
            &trust,
        ))
        .await?;
        Ok(RemoteSourceBundleRecoveryOutcome::Abandoned {
            request: stored.request,
            response: stored.response,
            trust,
        })
    }
}
