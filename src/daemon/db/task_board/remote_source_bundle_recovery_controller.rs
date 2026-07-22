use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_lease::require_assignment;
use super::remote_assignment_model::{concurrent, nonblank};
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
    consume_controller_operation_trust_in_tx,
    consume_successor_recovery_operation_trust_in_tx,
    require_source_recovery_operation_fence_in_tx,
};
use super::remote_source_bundle_abandonment::{
    TaskBoardRemoteSourceBundleAbandonment, insert_abandonment_in_tx,
    load_abandonment_collisions_in_tx, load_abandonment_in_tx,
};
use super::remote_source_bundles::{
    TaskBoardRemoteSourceBundle, insert_source_bundle_in_tx,
    load_source_bundle_collisions_in_tx, load_source_bundle_in_tx,
};
use crate::daemon::db::{
    AsyncDaemonDb, CliError, TaskBoardRemoteOfferOutcome, db_error,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteOfferRequest, RemoteOfferResponse, RemoteSourceBundleAbandonRequest,
    RemoteSourceBundleAbandonResponse,
    RemoteSourceBundleReceiptVerificationResponse, RemoteSourceBundleUploadRequest,
};
use crate::task_board::{TaskBoardExecutionAttemptCas, TaskBoardWorkflowExecutionCas};

impl AsyncDaemonDb {
    pub(crate) async fn adopt_verified_task_board_remote_source_bundle_receipt(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        verification: &RemoteSourceBundleReceiptVerificationResponse,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<TaskBoardRemoteSourceBundle>, CliError> {
        verification
            .validate(request)
            .map_err(|error| db_error(format!("validate verified source receipt: {error}")))?;
        nonblank(authenticated_principal, "verified source receipt principal")?;
        if verification.observed_host_instance_id != trust.observed_host_instance_id {
            return Err(concurrent(
                "verified source receipt came from a different current executor instance",
            ));
        }
        let mut transaction = self
            .begin_immediate_transaction("task board verified source upload receipt")
            .await?;
        require_source_recovery_operation_fence_in_tx(&mut transaction, trust).await?;
        let collisions = load_source_bundle_collisions_in_tx(&mut transaction, &request.offer)
            .await?;
        if let Some(existing) = exact_source_receipt(
            collisions,
            request,
            authenticated_principal,
        )? {
            if verification.receipt.as_ref() != Some(&existing.response) {
                return Err(concurrent(
                    "verified source receipt changed from controller evidence",
                ));
            }
            let operation_settled = settle_upload_operation_if_present(
                &mut transaction,
                request,
                authenticated_principal,
                trust,
            )
            .await?;
            if operation_settled {
                bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
            }
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit replayed verified source receipt: {error}"))
            })?;
            return Ok(Some(existing));
        }
        let assignment = require_assignment(
            &mut transaction,
            &request.offer.binding.assignment_id,
        )
        .await?;
        super::remote_source_bundle_controller::require_upload_assignment(
            &assignment,
            request,
            authenticated_principal,
        )?;
        require_upload_operation(&assignment, request)?;
        let Some(response) = verification.receipt.as_ref() else {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit verified source receipt absence: {error}"))
            })?;
            return Ok(None);
        };
        consume_upload_operation(&mut transaction, &assignment, request, trust).await?;
        insert_source_bundle_in_tx(
            &mut transaction,
            request,
            authenticated_principal,
            response,
        )
        .await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        let stored = load_source_bundle_in_tx(
            &mut transaction,
            &request.offer.binding.assignment_id,
            request.offer.binding.fencing_epoch,
        )
        .await?
        .ok_or_else(|| db_error("adopted verified source receipt disappeared"))?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit verified source receipt adoption: {error}"))
        })?;
        Ok(Some(stored))
    }

    pub(crate) async fn record_task_board_remote_source_bundle_abandonment(
        &self,
        request: &RemoteSourceBundleAbandonRequest,
        response: &RemoteSourceBundleAbandonResponse,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<TaskBoardRemoteSourceBundleAbandonment, CliError> {
        response
            .validate(request)
            .map_err(|error| db_error(format!("validate source abandonment response: {error}")))?;
        nonblank(authenticated_principal, "source abandonment principal")?;
        let mut transaction = self
            .begin_immediate_transaction("task board source abandonment response")
            .await?;
        require_source_recovery_operation_fence_in_tx(&mut transaction, trust).await?;
        let collisions = load_abandonment_collisions_in_tx(
            &mut transaction,
            &request.offer,
            &request.upload_request_sha256,
        )
        .await?;
        if let Some(existing) = exact_abandonment(
            collisions,
            request,
            authenticated_principal,
        )? {
            if existing.response != *response {
                return Err(concurrent(
                    "source abandonment response changed after immutable storage",
                ));
            }
            let operation_settled = settle_abandonment_operation_if_present(
                &mut transaction,
                request,
                authenticated_principal,
                trust,
            )
            .await?;
            if operation_settled {
                bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
            }
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit replayed source abandonment response: {error}"))
            })?;
            return Ok(existing);
        }
        if !load_source_bundle_collisions_in_tx(&mut transaction, &request.offer)
            .await?
            .is_empty()
        {
            return Err(concurrent(
                "source abandonment conflicts with an immutable upload receipt",
            ));
        }
        let assignment = require_assignment(
            &mut transaction,
            &request.offer.binding.assignment_id,
        )
        .await?;
        super::remote_source_bundle_controller::require_upload_assignment_without_content(
            &assignment,
            &request.offer,
            authenticated_principal,
        )?;
        require_upload_operation_for_abandonment(&assignment, request)?;
        consume_abandonment_operation(&mut transaction, &assignment, request, trust).await?;
        insert_abandonment_in_tx(
            &mut transaction,
            request,
            authenticated_principal,
            response,
        )
        .await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        let stored = load_abandonment_in_tx(
            &mut transaction,
            &request.offer.binding.assignment_id,
            request.offer.binding.fencing_epoch,
        )
        .await?
        .ok_or_else(|| db_error("persisted controller source abandonment disappeared"))?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit controller source abandonment: {error}"))
        })?;
        Ok(stored)
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn reassign_rejected_task_board_remote_source_bundle_offer(
        &self,
        expected_execution: &TaskBoardWorkflowExecutionCas,
        expected_attempt: &TaskBoardExecutionAttemptCas,
        predecessor: &RemoteOfferRequest,
        rejection: &RemoteOfferResponse,
        replacement: &RemoteOfferRequest,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
        offered_at: &str,
        lease_expires_at: &str,
    ) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
        self.reassign_task_board_remote_source_bundle_offer(
            expected_execution,
            expected_attempt,
            super::remote_source_bundle_reassignment_evidence::SourceReassignmentEvidence::OfferRejection {
                request: predecessor,
                response: rejection,
                observed_at: offered_at,
            },
            replacement,
            authenticated_principal,
            trust,
            offered_at,
            lease_expires_at,
        )
        .await
    }
}

fn exact_source_receipt(
    collisions: Vec<TaskBoardRemoteSourceBundle>,
    request: &RemoteSourceBundleUploadRequest,
    principal: &str,
) -> Result<Option<TaskBoardRemoteSourceBundle>, CliError> {
    match collisions.as_slice() {
        [] => Ok(None),
        [stored] if stored.is_exact_replay(request, principal) => Ok(Some(stored.clone())),
        _ => Err(concurrent(
            "verified source receipt identity or generation conflicts",
        )),
    }
}

fn exact_abandonment(
    collisions: Vec<TaskBoardRemoteSourceBundleAbandonment>,
    request: &RemoteSourceBundleAbandonRequest,
    principal: &str,
) -> Result<Option<TaskBoardRemoteSourceBundleAbandonment>, CliError> {
    match collisions.as_slice() {
        [] => Ok(None),
        [stored] if stored.is_exact_replay(request, principal) => {
            Ok(Some(stored.clone()))
        }
        _ => Err(concurrent(
            "source abandonment identity or generation conflicts",
        )),
    }
}

fn require_upload_operation(
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteSourceBundleUploadRequest,
) -> Result<(), CliError> {
    let exact = assignment.controller_operation.as_ref().is_some_and(|operation| {
        operation.kind == TaskBoardRemoteOperationKind::UploadSourceBundle.as_str()
            && operation.request_sha256 == request.request_sha256
    });
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "verified source receipt lost its pending upload operation",
        ))
    }
}

fn require_upload_operation_for_abandonment(
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteSourceBundleAbandonRequest,
) -> Result<(), CliError> {
    let exact = assignment.controller_operation.as_ref().is_some_and(|operation| {
        operation.kind == TaskBoardRemoteOperationKind::UploadSourceBundle.as_str()
            && operation.request_sha256 == request.upload_request_sha256
    });
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "source abandonment lost its pending upload operation",
        ))
    }
}

async fn settle_upload_operation_if_present(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    request: &RemoteSourceBundleUploadRequest,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<bool, CliError> {
    let assignment = require_assignment(transaction, &request.offer.binding.assignment_id).await?;
    if assignment.controller_operation.is_none() {
        return Ok(false);
    }
    super::remote_source_bundle_controller::require_upload_assignment(
        &assignment,
        request,
        principal,
    )?;
    require_upload_operation(&assignment, request)?;
    consume_upload_operation(transaction, &assignment, request, trust).await?;
    Ok(true)
}

async fn settle_abandonment_operation_if_present(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    request: &RemoteSourceBundleAbandonRequest,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<bool, CliError> {
    let assignment = require_assignment(transaction, &request.offer.binding.assignment_id).await?;
    if assignment.controller_operation.is_none() {
        return Ok(false);
    }
    super::remote_source_bundle_controller::require_upload_assignment_without_content(
        &assignment,
        &request.offer,
        principal,
    )?;
    require_upload_operation_for_abandonment(&assignment, request)?;
    consume_abandonment_operation(transaction, &assignment, request, trust).await?;
    Ok(true)
}

async fn consume_upload_operation(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteSourceBundleUploadRequest,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<(), CliError> {
    if assignment.target_host_instance_id.as_deref()
        == Some(trust.observed_host_instance_id.as_str())
    {
        consume_controller_operation_trust_in_tx(
            transaction,
            assignment,
            TaskBoardRemoteOperationKind::UploadSourceBundle,
            &request.request_sha256,
        )
        .await
    } else {
        consume_successor_recovery_operation_trust_in_tx(
            transaction,
            assignment,
            TaskBoardRemoteOperationKind::UploadSourceBundle,
            &request.request_sha256,
            trust,
        )
        .await
    }
}

async fn consume_abandonment_operation(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteSourceBundleAbandonRequest,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<(), CliError> {
    if assignment.target_host_instance_id.as_deref()
        == Some(trust.observed_host_instance_id.as_str())
    {
        consume_controller_operation_trust_in_tx(
            transaction,
            assignment,
            TaskBoardRemoteOperationKind::UploadSourceBundle,
            &request.upload_request_sha256,
        )
        .await
    } else {
        consume_successor_recovery_operation_trust_in_tx(
            transaction,
            assignment,
            TaskBoardRemoteOperationKind::UploadSourceBundle,
            &request.upload_request_sha256,
            trust,
        )
        .await
    }
}
