use std::future::Future;
use std::pin::Pin;

use super::remote_artifact_fetch_response;
use super::remote_artifacts::{self, TaskBoardRemoteArtifact, TaskBoardRemoteArtifactStoreInput};
use super::remote_operation_trust::TaskBoardRemoteOperationTrustFence;
use super::remote_source_bundle_abandonment::{
    self, TaskBoardRemoteSourceBundleAbandonment,
};
use super::remote_source_bundle_controller;
use super::remote_source_bundle_prior::{self, TaskBoardRemotePriorPhaseBundle};
use super::remote_source_bundle_reassignment::{self, TaskBoardRemoteSourceOfferReassignment};
use super::remote_source_bundle_reassignment_evidence::SourceReassignmentEvidence;
use super::remote_source_bundle_recovery_controller;
use super::remote_source_bundles::{self, TaskBoardRemoteSourceBundle};
use crate::daemon::db::{AsyncDaemonDb, CliError, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteOfferOutcome};
use crate::task_board::remote_wire::wire::{
    RemoteArtifactFetchRequest, RemoteArtifactFetchResponse, RemoteOfferRequest,
    RemoteOfferResponse, RemoteSourceBundleAbandonRequest, RemoteSourceBundleAbandonResponse,
    RemoteSourceBundleReceiptVerificationResponse, RemoteSourceBundleUploadRequest,
    RemoteSourceBundleUploadResponse,
};
use crate::task_board::{TaskBoardExecutionPhase, TaskBoardWorkflowExecutionRecord};

// Reassignment sits several `Box::pin` frames deep already (see
// remote_source_bundle_reassignment.rs and its `replay` submodule); this trait's
// forwarding frame tips the chain over the crate's recursion limit checking
// `Send` unless it erases to a `dyn Future` here instead of merely boxing the
// concrete (still fully-named) future type.
type ReassignmentOutcomeFuture<'a> =
    Pin<Box<dyn Future<Output = Result<TaskBoardRemoteOfferOutcome, CliError>> + Send + 'a>>;

pub(crate) trait RemoteSourceBundleQueries: Send + Sync {
    async fn record_task_board_remote_artifact_fetch_response(
        &self,
        request: &RemoteArtifactFetchRequest,
        response: &RemoteArtifactFetchResponse,
        authenticated_principal: &str,
        stored_at: &str,
    ) -> Result<TaskBoardRemoteArtifact, CliError>;

    async fn claim_task_board_remote_artifact_fetch_io_authority_fenced(
        &self,
        request: &RemoteArtifactFetchRequest,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<bool, CliError>;

    async fn store_task_board_remote_artifact(
        &self,
        input: &TaskBoardRemoteArtifactStoreInput<'_>,
    ) -> Result<TaskBoardRemoteArtifact, CliError>;

    async fn task_board_remote_artifact(
        &self,
        request: &RemoteArtifactFetchRequest,
        authenticated_principal: &str,
    ) -> Result<Option<TaskBoardRemoteArtifact>, CliError>;

    async fn exact_task_board_remote_source_bundle_abandonment(
        &self,
        upload: &RemoteSourceBundleUploadRequest,
        authenticated_principal: &str,
    ) -> Result<Option<TaskBoardRemoteSourceBundleAbandonment>, CliError>;

    async fn verify_task_board_remote_source_bundle_receipt(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        authenticated_principal: &str,
        observed_host_instance_id: &str,
        checked_at: &str,
    ) -> Result<RemoteSourceBundleReceiptVerificationResponse, CliError>;

    async fn abandon_task_board_remote_source_bundle(
        &self,
        request: &RemoteSourceBundleAbandonRequest,
        authenticated_principal: &str,
        observed_host_instance_id: &str,
        abandoned_at: &str,
    ) -> Result<TaskBoardRemoteSourceBundleAbandonment, CliError>;

    async fn exact_task_board_remote_source_bundle_upload_receipt(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        authenticated_principal: &str,
    ) -> Result<Option<TaskBoardRemoteSourceBundle>, CliError>;

    async fn claim_task_board_remote_source_bundle_upload_io_authority_fenced(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<bool, CliError>;

    async fn record_task_board_remote_source_bundle_upload_response(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        response: &RemoteSourceBundleUploadResponse,
        authenticated_principal: &str,
    ) -> Result<TaskBoardRemoteSourceBundle, CliError>;

    #[cfg(test)]
    async fn insert_task_board_remote_source_bundle_offer_for_test(
        &self,
        request: &RemoteOfferRequest,
        principal: &str,
        offered_at: &str,
        lease_expires_at: &str,
        deadline_at: &str,
    ) -> Result<(), CliError>;

    async fn task_board_remote_prior_phase_bundle(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
        phase: TaskBoardExecutionPhase,
    ) -> Result<Option<TaskBoardRemotePriorPhaseBundle>, CliError>;

    async fn reassign_abandoned_task_board_remote_source_bundle_offer(
        &self,
        reassignment: &TaskBoardRemoteSourceOfferReassignment<'_>,
        abandonment_request: &RemoteSourceBundleAbandonRequest,
        abandonment_response: &RemoteSourceBundleAbandonResponse,
    ) -> Result<TaskBoardRemoteOfferOutcome, CliError>;

    async fn reassign_task_board_remote_source_bundle_offer(
        &self,
        reassignment: &TaskBoardRemoteSourceOfferReassignment<'_>,
        evidence: SourceReassignmentEvidence<'_>,
    ) -> Result<TaskBoardRemoteOfferOutcome, CliError>;

    async fn adopt_verified_task_board_remote_source_bundle_receipt(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        verification: &RemoteSourceBundleReceiptVerificationResponse,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<TaskBoardRemoteSourceBundle>, CliError>;

    async fn record_task_board_remote_source_bundle_abandonment(
        &self,
        request: &RemoteSourceBundleAbandonRequest,
        response: &RemoteSourceBundleAbandonResponse,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<TaskBoardRemoteSourceBundleAbandonment, CliError>;

    async fn reassign_rejected_task_board_remote_source_bundle_offer(
        &self,
        reassignment: &TaskBoardRemoteSourceOfferReassignment<'_>,
        predecessor: &RemoteOfferRequest,
        rejection: &RemoteOfferResponse,
    ) -> Result<TaskBoardRemoteOfferOutcome, CliError>;

    async fn store_task_board_remote_source_bundle(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        authenticated_principal: &str,
        host_instance_id: &str,
        stored_at: &str,
    ) -> Result<TaskBoardRemoteSourceBundle, CliError>;

    async fn task_board_remote_source_bundle(
        &self,
        assignment: &TaskBoardRemoteAssignmentRecord,
    ) -> Result<Option<TaskBoardRemoteSourceBundle>, CliError>;
}

impl RemoteSourceBundleQueries for AsyncDaemonDb {
    async fn record_task_board_remote_artifact_fetch_response(
        &self,
        request: &RemoteArtifactFetchRequest,
        response: &RemoteArtifactFetchResponse,
        authenticated_principal: &str,
        stored_at: &str,
    ) -> Result<TaskBoardRemoteArtifact, CliError> {
        remote_artifact_fetch_response::record_task_board_remote_artifact_fetch_response(
            self,
            request,
            response,
            authenticated_principal,
            stored_at,
        )
        .await
    }

    async fn claim_task_board_remote_artifact_fetch_io_authority_fenced(
        &self,
        request: &RemoteArtifactFetchRequest,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<bool, CliError> {
        remote_artifacts::claim_task_board_remote_artifact_fetch_io_authority_fenced(
            self,
            request,
            authenticated_principal,
            trust,
        )
        .await
    }

    async fn store_task_board_remote_artifact(
        &self,
        input: &TaskBoardRemoteArtifactStoreInput<'_>,
    ) -> Result<TaskBoardRemoteArtifact, CliError> {
        remote_artifacts::store_task_board_remote_artifact(self, input).await
    }

    async fn task_board_remote_artifact(
        &self,
        request: &RemoteArtifactFetchRequest,
        authenticated_principal: &str,
    ) -> Result<Option<TaskBoardRemoteArtifact>, CliError> {
        remote_artifacts::task_board_remote_artifact(self, request, authenticated_principal).await
    }

    async fn exact_task_board_remote_source_bundle_abandonment(
        &self,
        upload: &RemoteSourceBundleUploadRequest,
        authenticated_principal: &str,
    ) -> Result<Option<TaskBoardRemoteSourceBundleAbandonment>, CliError> {
        remote_source_bundle_abandonment::exact_task_board_remote_source_bundle_abandonment(
            self,
            upload,
            authenticated_principal,
        )
        .await
    }

    async fn verify_task_board_remote_source_bundle_receipt(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        authenticated_principal: &str,
        observed_host_instance_id: &str,
        checked_at: &str,
    ) -> Result<RemoteSourceBundleReceiptVerificationResponse, CliError> {
        remote_source_bundle_abandonment::verify_task_board_remote_source_bundle_receipt(
            self,
            request,
            authenticated_principal,
            observed_host_instance_id,
            checked_at,
        )
        .await
    }

    async fn abandon_task_board_remote_source_bundle(
        &self,
        request: &RemoteSourceBundleAbandonRequest,
        authenticated_principal: &str,
        observed_host_instance_id: &str,
        abandoned_at: &str,
    ) -> Result<TaskBoardRemoteSourceBundleAbandonment, CliError> {
        remote_source_bundle_abandonment::abandon_task_board_remote_source_bundle(
            self,
            request,
            authenticated_principal,
            observed_host_instance_id,
            abandoned_at,
        )
        .await
    }

    async fn exact_task_board_remote_source_bundle_upload_receipt(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        authenticated_principal: &str,
    ) -> Result<Option<TaskBoardRemoteSourceBundle>, CliError> {
        remote_source_bundle_controller::exact_task_board_remote_source_bundle_upload_receipt(
            self,
            request,
            authenticated_principal,
        )
        .await
    }

    async fn claim_task_board_remote_source_bundle_upload_io_authority_fenced(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<bool, CliError> {
        remote_source_bundle_controller::claim_task_board_remote_source_bundle_upload_io_authority_fenced(
            self,
            request,
            authenticated_principal,
            trust,
        )
        .await
    }

    async fn record_task_board_remote_source_bundle_upload_response(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        response: &RemoteSourceBundleUploadResponse,
        authenticated_principal: &str,
    ) -> Result<TaskBoardRemoteSourceBundle, CliError> {
        remote_source_bundle_controller::record_task_board_remote_source_bundle_upload_response(
            self,
            request,
            response,
            authenticated_principal,
        )
        .await
    }

    #[cfg(test)]
    async fn insert_task_board_remote_source_bundle_offer_for_test(
        &self,
        request: &RemoteOfferRequest,
        principal: &str,
        offered_at: &str,
        lease_expires_at: &str,
        deadline_at: &str,
    ) -> Result<(), CliError> {
        remote_source_bundle_controller::insert_task_board_remote_source_bundle_offer_for_test(
            self,
            request,
            principal,
            offered_at,
            lease_expires_at,
            deadline_at,
        )
        .await
    }

    async fn task_board_remote_prior_phase_bundle(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
        phase: TaskBoardExecutionPhase,
    ) -> Result<Option<TaskBoardRemotePriorPhaseBundle>, CliError> {
        remote_source_bundle_prior::task_board_remote_prior_phase_bundle(self, execution, phase)
            .await
    }

    async fn reassign_abandoned_task_board_remote_source_bundle_offer(
        &self,
        reassignment: &TaskBoardRemoteSourceOfferReassignment<'_>,
        abandonment_request: &RemoteSourceBundleAbandonRequest,
        abandonment_response: &RemoteSourceBundleAbandonResponse,
    ) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
        let future: ReassignmentOutcomeFuture<'_> = Box::pin(
            remote_source_bundle_reassignment::reassign_abandoned_task_board_remote_source_bundle_offer(
                self,
                reassignment,
                abandonment_request,
                abandonment_response,
            ),
        );
        future.await
    }

    async fn reassign_task_board_remote_source_bundle_offer(
        &self,
        reassignment: &TaskBoardRemoteSourceOfferReassignment<'_>,
        evidence: SourceReassignmentEvidence<'_>,
    ) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
        let future: ReassignmentOutcomeFuture<'_> = Box::pin(
            remote_source_bundle_reassignment::reassign_task_board_remote_source_bundle_offer(
                self,
                reassignment,
                evidence,
            ),
        );
        future.await
    }

    async fn adopt_verified_task_board_remote_source_bundle_receipt(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        verification: &RemoteSourceBundleReceiptVerificationResponse,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<TaskBoardRemoteSourceBundle>, CliError> {
        remote_source_bundle_recovery_controller::adopt_verified_task_board_remote_source_bundle_receipt(
            self,
            request,
            verification,
            authenticated_principal,
            trust,
        )
        .await
    }

    async fn record_task_board_remote_source_bundle_abandonment(
        &self,
        request: &RemoteSourceBundleAbandonRequest,
        response: &RemoteSourceBundleAbandonResponse,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<TaskBoardRemoteSourceBundleAbandonment, CliError> {
        remote_source_bundle_recovery_controller::record_task_board_remote_source_bundle_abandonment(
            self,
            request,
            response,
            authenticated_principal,
            trust,
        )
        .await
    }

    async fn reassign_rejected_task_board_remote_source_bundle_offer(
        &self,
        reassignment: &TaskBoardRemoteSourceOfferReassignment<'_>,
        predecessor: &RemoteOfferRequest,
        rejection: &RemoteOfferResponse,
    ) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
        let future: ReassignmentOutcomeFuture<'_> = Box::pin(
            remote_source_bundle_recovery_controller::reassign_rejected_task_board_remote_source_bundle_offer(
                self,
                reassignment,
                predecessor,
                rejection,
            ),
        );
        future.await
    }

    async fn store_task_board_remote_source_bundle(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        authenticated_principal: &str,
        host_instance_id: &str,
        stored_at: &str,
    ) -> Result<TaskBoardRemoteSourceBundle, CliError> {
        remote_source_bundles::store_task_board_remote_source_bundle(
            self,
            request,
            authenticated_principal,
            host_instance_id,
            stored_at,
        )
        .await
    }

    async fn task_board_remote_source_bundle(
        &self,
        assignment: &TaskBoardRemoteAssignmentRecord,
    ) -> Result<Option<TaskBoardRemoteSourceBundle>, CliError> {
        remote_source_bundles::task_board_remote_source_bundle(self, assignment).await
    }
}
