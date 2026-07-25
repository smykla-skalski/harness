use sqlx::{Sqlite, Transaction};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_lease::require_assignment;
use super::remote_assignment_model::{concurrent, nonblank};
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
    consume_controller_operation_trust_in_tx, consume_successor_recovery_operation_trust_in_tx,
    require_source_recovery_operation_fence_in_tx,
};
use super::remote_source_bundle_abandonment::{
    TaskBoardRemoteSourceBundleAbandonment, insert_abandonment_in_tx,
    load_abandonment_collisions_in_tx, load_abandonment_in_tx,
};
use super::remote_source_bundles::{
    TaskBoardRemoteSourceBundle, insert_source_bundle_in_tx, load_source_bundle_collisions_in_tx,
    load_source_bundle_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, TaskBoardRemoteOfferOutcome, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteOfferRequest, RemoteOfferResponse, RemoteSourceBundleAbandonRequest,
    RemoteSourceBundleAbandonResponse, RemoteSourceBundleReceiptVerificationResponse,
    RemoteSourceBundleUploadRequest, RemoteSourceBundleUploadResponse,
};
impl AsyncDaemonDb {
    pub(crate) async fn adopt_verified_task_board_remote_source_bundle_receipt(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        verification: &RemoteSourceBundleReceiptVerificationResponse,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<TaskBoardRemoteSourceBundle>, CliError> {
        validate_verified_receipt_input(request, verification, authenticated_principal, trust)?;
        let mut transaction = self
            .begin_immediate_transaction("task board verified source upload receipt")
            .await?;
        let (receipt, context) = adopt_verified_receipt_in_tx(
            &mut transaction,
            request,
            verification,
            authenticated_principal,
            trust,
        )
        .await?;
        commit(transaction, context).await?;
        Ok(receipt)
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
        let (stored, context) = record_abandonment_in_tx(
            &mut transaction,
            request,
            response,
            authenticated_principal,
            trust,
        )
        .await?;
        commit(transaction, context).await?;
        Ok(stored)
    }

    pub(crate) async fn reassign_rejected_task_board_remote_source_bundle_offer(
        &self,
        reassignment: &super::remote_source_bundle_reassignment::TaskBoardRemoteSourceOfferReassignment<
            '_,
        >,
        predecessor: &RemoteOfferRequest,
        rejection: &RemoteOfferResponse,
    ) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
        Box::pin(self.reassign_task_board_remote_source_bundle_offer(
            reassignment,
            super::remote_source_bundle_reassignment_evidence::SourceReassignmentEvidence::OfferRejection {
                request: predecessor,
                response: rejection,
                observed_at: reassignment.offered_at,
            },
        ))
        .await
    }
}

async fn adopt_verified_receipt_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSourceBundleUploadRequest,
    verification: &RemoteSourceBundleReceiptVerificationResponse,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<(Option<TaskBoardRemoteSourceBundle>, &'static str), CliError> {
    require_source_recovery_operation_fence_in_tx(transaction, trust).await?;
    if let Some(existing) =
        settled_replayed_source_receipt_in_tx(transaction, request, verification, principal, trust)
            .await?
    {
        return Ok((Some(existing), "replayed verified source receipt"));
    }
    let assignment =
        require_adoptable_upload_assignment_in_tx(transaction, request, principal).await?;
    let Some(response) = verification.receipt.as_ref() else {
        return Ok((None, "verified source receipt absence"));
    };
    let stored = store_adopted_source_receipt_in_tx(
        transaction,
        AdoptedSourceReceipt {
            assignment: &assignment,
            request,
            response,
            authenticated_principal: principal,
            trust,
        },
    )
    .await?;
    Ok((Some(stored), "verified source receipt adoption"))
}

async fn record_abandonment_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSourceBundleAbandonRequest,
    response: &RemoteSourceBundleAbandonResponse,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<(TaskBoardRemoteSourceBundleAbandonment, &'static str), CliError> {
    require_source_recovery_operation_fence_in_tx(transaction, trust).await?;
    if let Some(existing) =
        settled_replayed_abandonment_in_tx(transaction, request, response, principal, trust).await?
    {
        return Ok((existing, "replayed source abandonment response"));
    }
    require_no_upload_receipt_conflict_in_tx(transaction, &request.offer).await?;
    let stored =
        store_source_abandonment_in_tx(transaction, request, response, principal, trust).await?;
    Ok((stored, "controller source abandonment"))
}

async fn commit(transaction: Transaction<'_, Sqlite>, context: &str) -> Result<(), CliError> {
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit {context}: {error}")))
}

fn validate_verified_receipt_input(
    request: &RemoteSourceBundleUploadRequest,
    verification: &RemoteSourceBundleReceiptVerificationResponse,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<(), CliError> {
    verification
        .validate(request)
        .map_err(|error| db_error(format!("validate verified source receipt: {error}")))?;
    nonblank(principal, "verified source receipt principal")?;
    if verification.observed_host_instance_id == trust.observed_host_instance_id {
        Ok(())
    } else {
        Err(concurrent(
            "verified source receipt came from a different current executor instance",
        ))
    }
}

async fn require_no_upload_receipt_conflict_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    offer: &RemoteOfferRequest,
) -> Result<(), CliError> {
    if load_source_bundle_collisions_in_tx(transaction, offer)
        .await?
        .is_empty()
    {
        Ok(())
    } else {
        Err(concurrent(
            "source abandonment conflicts with an immutable upload receipt",
        ))
    }
}

async fn settled_replayed_source_receipt_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSourceBundleUploadRequest,
    verification: &RemoteSourceBundleReceiptVerificationResponse,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<Option<TaskBoardRemoteSourceBundle>, CliError> {
    let collisions = load_source_bundle_collisions_in_tx(transaction, &request.offer).await?;
    let Some(existing) = exact_source_receipt(&collisions, request, principal)? else {
        return Ok(None);
    };
    settle_replayed_source_receipt_in_tx(
        transaction,
        request,
        verification,
        principal,
        trust,
        &existing,
    )
    .await?;
    Ok(Some(existing))
}

async fn require_adoptable_upload_assignment_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSourceBundleUploadRequest,
    principal: &str,
) -> Result<super::TaskBoardRemoteAssignmentRecord, CliError> {
    let assignment = require_assignment(transaction, &request.offer.binding.assignment_id).await?;
    super::remote_source_bundle_controller::require_upload_assignment(
        &assignment,
        request,
        principal,
    )?;
    require_upload_operation(&assignment, request)?;
    Ok(assignment)
}

async fn settled_replayed_abandonment_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSourceBundleAbandonRequest,
    response: &RemoteSourceBundleAbandonResponse,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<Option<TaskBoardRemoteSourceBundleAbandonment>, CliError> {
    let collisions = load_abandonment_collisions_in_tx(
        transaction,
        &request.offer,
        &request.upload_request_sha256,
    )
    .await?;
    let Some(existing) = exact_abandonment(&collisions, request, principal)? else {
        return Ok(None);
    };
    settle_replayed_abandonment_in_tx(transaction, request, response, principal, trust, &existing)
        .await?;
    Ok(Some(existing))
}

async fn settle_replayed_source_receipt_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSourceBundleUploadRequest,
    verification: &RemoteSourceBundleReceiptVerificationResponse,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
    existing: &TaskBoardRemoteSourceBundle,
) -> Result<(), CliError> {
    if verification.receipt.as_ref() != Some(&existing.response) {
        return Err(concurrent(
            "verified source receipt changed from controller evidence",
        ));
    }
    if settle_upload_operation_if_present(transaction, request, principal, trust).await? {
        bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    }
    Ok(())
}

struct AdoptedSourceReceipt<'a> {
    assignment: &'a super::TaskBoardRemoteAssignmentRecord,
    request: &'a RemoteSourceBundleUploadRequest,
    response: &'a RemoteSourceBundleUploadResponse,
    authenticated_principal: &'a str,
    trust: &'a TaskBoardRemoteOperationTrustFence,
}

async fn store_adopted_source_receipt_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    adopted: AdoptedSourceReceipt<'_>,
) -> Result<TaskBoardRemoteSourceBundle, CliError> {
    let AdoptedSourceReceipt {
        assignment,
        request,
        response,
        authenticated_principal,
        trust,
    } = adopted;
    consume_upload_operation(transaction, assignment, request, trust).await?;
    insert_source_bundle_in_tx(transaction, request, authenticated_principal, response).await?;
    bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    load_source_bundle_in_tx(
        transaction,
        &request.offer.binding.assignment_id,
        request.offer.binding.fencing_epoch,
    )
    .await?
    .ok_or_else(|| db_error("adopted verified source receipt disappeared"))
}

async fn settle_replayed_abandonment_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSourceBundleAbandonRequest,
    response: &RemoteSourceBundleAbandonResponse,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
    existing: &TaskBoardRemoteSourceBundleAbandonment,
) -> Result<(), CliError> {
    if existing.response != *response {
        return Err(concurrent(
            "source abandonment response changed after immutable storage",
        ));
    }
    if settle_abandonment_operation_if_present(transaction, request, principal, trust).await? {
        bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    }
    Ok(())
}

async fn store_source_abandonment_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSourceBundleAbandonRequest,
    response: &RemoteSourceBundleAbandonResponse,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<TaskBoardRemoteSourceBundleAbandonment, CliError> {
    let assignment = require_assignment(transaction, &request.offer.binding.assignment_id).await?;
    super::remote_source_bundle_controller::require_upload_assignment_without_content(
        &assignment,
        &request.offer,
        principal,
    )?;
    require_upload_operation_for_abandonment(&assignment, request)?;
    consume_abandonment_operation(transaction, &assignment, request, trust).await?;
    insert_abandonment_in_tx(transaction, request, principal, response).await?;
    bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    load_abandonment_in_tx(
        transaction,
        &request.offer.binding.assignment_id,
        request.offer.binding.fencing_epoch,
    )
    .await?
    .ok_or_else(|| db_error("persisted controller source abandonment disappeared"))
}

fn exact_source_receipt(
    collisions: &[TaskBoardRemoteSourceBundle],
    request: &RemoteSourceBundleUploadRequest,
    principal: &str,
) -> Result<Option<TaskBoardRemoteSourceBundle>, CliError> {
    match collisions {
        [] => Ok(None),
        [stored] if stored.is_exact_replay(request, principal) => Ok(Some(stored.clone())),
        _ => Err(concurrent(
            "verified source receipt identity or generation conflicts",
        )),
    }
}

fn exact_abandonment(
    collisions: &[TaskBoardRemoteSourceBundleAbandonment],
    request: &RemoteSourceBundleAbandonRequest,
    principal: &str,
) -> Result<Option<TaskBoardRemoteSourceBundleAbandonment>, CliError> {
    match collisions {
        [] => Ok(None),
        [stored] if stored.is_exact_replay(request, principal) => Ok(Some(stored.clone())),
        _ => Err(concurrent(
            "source abandonment identity or generation conflicts",
        )),
    }
}

fn require_upload_operation(
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteSourceBundleUploadRequest,
) -> Result<(), CliError> {
    let exact = assignment
        .controller_operation
        .as_ref()
        .is_some_and(|operation| {
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
    let exact = assignment
        .controller_operation
        .as_ref()
        .is_some_and(|operation| {
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
    transaction: &mut Transaction<'_, Sqlite>,
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
    transaction: &mut Transaction<'_, Sqlite>,
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
    transaction: &mut Transaction<'_, Sqlite>,
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
    transaction: &mut Transaction<'_, Sqlite>,
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
