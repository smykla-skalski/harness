use sqlx::{Sqlite, Transaction};

use super::super::remote_assignment_lease::require_assignment;
use super::super::remote_assignment_model::concurrent;
use super::super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
    consume_controller_operation_trust_in_tx, consume_successor_recovery_operation_trust_in_tx,
};
use crate::daemon::db::CliError;
use crate::task_board::remote_wire::wire::{
    RemoteSourceBundleAbandonRequest, RemoteSourceBundleUploadRequest,
};

pub(super) fn require_upload_operation(
    assignment: &super::super::TaskBoardRemoteAssignmentRecord,
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

pub(super) fn require_upload_operation_for_abandonment(
    assignment: &super::super::TaskBoardRemoteAssignmentRecord,
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

pub(super) async fn settle_upload_operation_if_present(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSourceBundleUploadRequest,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<bool, CliError> {
    let assignment = require_assignment(transaction, &request.offer.binding.assignment_id).await?;
    if assignment.controller_operation.is_none() {
        return Ok(false);
    }
    super::super::remote_source_bundle_controller::require_upload_assignment(
        &assignment,
        request,
        principal,
    )?;
    require_upload_operation(&assignment, request)?;
    consume_upload_operation(transaction, &assignment, request, trust).await?;
    Ok(true)
}

pub(super) async fn settle_abandonment_operation_if_present(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSourceBundleAbandonRequest,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<bool, CliError> {
    let assignment = require_assignment(transaction, &request.offer.binding.assignment_id).await?;
    if assignment.controller_operation.is_none() {
        return Ok(false);
    }
    super::super::remote_source_bundle_controller::require_upload_assignment_without_content(
        &assignment,
        &request.offer,
        principal,
    )?;
    require_upload_operation_for_abandonment(&assignment, request)?;
    consume_abandonment_operation(transaction, &assignment, request, trust).await?;
    Ok(true)
}

pub(super) async fn consume_upload_operation(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &super::super::TaskBoardRemoteAssignmentRecord,
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

pub(super) async fn consume_abandonment_operation(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &super::super::TaskBoardRemoteAssignmentRecord,
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
