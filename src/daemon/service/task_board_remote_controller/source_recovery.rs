use super::{canonical_now, controller_database_error, missing_execution, requests};
use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome,
    TaskBoardRemoteOfferOutcome, TaskBoardRemoteOperationTrustFence,
    TaskBoardRemoteSourceOfferReassignment,
};
use crate::daemon::task_board_remote_transport::controller::RemoteExecutionControllerClient;
use crate::daemon::task_board_remote_transport::controller_offer_recovery::RemotePredecessorOfferRecoveryOutcome;
use crate::daemon::task_board_remote_transport::controller_source_bundle::RemoteSourceBundleRecoveryOutcome;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteOfferRequest, RemoteOfferResponse, RemoteSourceBundleAbandonRequest,
    RemoteSourceBundleAbandonResponse, RemoteSourceBundleUploadRequest,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptRecord, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord,
};

pub(super) async fn progress_unclaimed_offer(
    db: &AsyncDaemonDb,
    client: &RemoteExecutionControllerClient,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Result<bool, CliError> {
    let offer = assignment.require_offer()?;
    if !offer.source.requires_upload() {
        return Box::pin(client.offer(db, offer))
            .await
            .map(|_| true)
            .map_err(controller_database_error);
    }
    let upload = exact_outbound_upload(db, assignment, offer).await?;
    match Box::pin(client.verify_or_abandon_predecessor_source_bundle(db, &upload))
        .await
        .map_err(controller_database_error)?
    {
        RemoteSourceBundleRecoveryOutcome::CurrentGeneration => {
            Box::pin(client.upload_source_bundle(db, &upload))
                .await
                .map_err(controller_database_error)?;
            Box::pin(client.offer(db, offer))
                .await
                .map(|_| true)
                .map_err(controller_database_error)
        }
        RemoteSourceBundleRecoveryOutcome::Receipt { trust, .. } => {
            Box::pin(recover_offer_after_source_receipt(
                db, client, assignment, offer, &trust,
            ))
            .await
        }
        RemoteSourceBundleRecoveryOutcome::Abandoned {
            request,
            response,
            trust,
        } => {
            Box::pin(reassign_abandoned_source(
                db, assignment, &request, &response, &trust,
            ))
            .await
        }
    }
}

async fn recover_offer_after_source_receipt(
    db: &AsyncDaemonDb,
    client: &RemoteExecutionControllerClient,
    assignment: &TaskBoardRemoteAssignmentRecord,
    offer: &RemoteOfferRequest,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<bool, CliError> {
    match Box::pin(client.recover_predecessor_offer(db, offer, trust))
        .await
        .map_err(controller_database_error)?
    {
        RemotePredecessorOfferRecoveryOutcome::Accepted { outcome } => Ok(matches!(
            *outcome,
            TaskBoardRemoteMutationOutcome::Updated(_)
                | TaskBoardRemoteMutationOutcome::Replayed(_)
        )),
        RemotePredecessorOfferRecoveryOutcome::Rejected(response) => {
            Box::pin(reassign_rejected_offer(
                db, assignment, offer, &response, trust,
            ))
            .await
        }
    }
}

async fn reassign_abandoned_source(
    db: &AsyncDaemonDb,
    assignment: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteSourceBundleAbandonRequest,
    response: &RemoteSourceBundleAbandonResponse,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<bool, CliError> {
    let context = reassignment_context(db, assignment, &request.offer, trust).await?;
    let expected_execution = TaskBoardWorkflowExecutionCas::from(&context.execution);
    let expected_attempt = TaskBoardExecutionAttemptCas::from(&context.attempt);
    let reassignment = TaskBoardRemoteSourceOfferReassignment {
        expected_execution: &expected_execution,
        expected_attempt: &expected_attempt,
        replacement: &context.replacement.request,
        authenticated_principal: &assignment.host_id,
        trust,
        offered_at: &context.replacement.offered_at,
        lease_expires_at: &context.replacement.lease_expires_at,
    };
    Box::pin(db.reassign_abandoned_task_board_remote_source_bundle_offer(
        &reassignment,
        request,
        response,
    ))
    .await
    .map(|outcome| reassignment_progressed(&outcome))
}

async fn reassign_rejected_offer(
    db: &AsyncDaemonDb,
    assignment: &TaskBoardRemoteAssignmentRecord,
    offer: &RemoteOfferRequest,
    response: &RemoteOfferResponse,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<bool, CliError> {
    let context = reassignment_context(db, assignment, offer, trust).await?;
    let expected_execution = TaskBoardWorkflowExecutionCas::from(&context.execution);
    let expected_attempt = TaskBoardExecutionAttemptCas::from(&context.attempt);
    let reassignment = TaskBoardRemoteSourceOfferReassignment {
        expected_execution: &expected_execution,
        expected_attempt: &expected_attempt,
        replacement: &context.replacement.request,
        authenticated_principal: &assignment.host_id,
        trust,
        offered_at: &context.replacement.offered_at,
        lease_expires_at: &context.replacement.lease_expires_at,
    };
    Box::pin(db.reassign_rejected_task_board_remote_source_bundle_offer(
        &reassignment,
        offer,
        response,
    ))
    .await
    .map(|outcome| reassignment_progressed(&outcome))
}

struct ReassignmentContext {
    execution: TaskBoardWorkflowExecutionRecord,
    attempt: TaskBoardExecutionAttemptRecord,
    replacement: requests::PreparedRemoteReassignment,
}

async fn reassignment_context(
    db: &AsyncDaemonDb,
    assignment: &TaskBoardRemoteAssignmentRecord,
    predecessor: &RemoteOfferRequest,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<ReassignmentContext, CliError> {
    let execution = db
        .task_board_workflow_execution(&predecessor.binding.execution_id)
        .await?
        .ok_or_else(missing_execution)?;
    let attempt = execution
        .attempts
        .iter()
        .find(|candidate| {
            candidate.action_key == predecessor.binding.action_key
                && candidate.attempt == predecessor.binding.attempt
        })
        .cloned()
        .ok_or_else(|| {
            CliErrorKind::concurrent_modification("remote source reassignment attempt disappeared")
        })?;
    if assignment.assignment_id != predecessor.binding.assignment_id {
        return Err(CliErrorKind::concurrent_modification(
            "remote source reassignment changed predecessor generation",
        )
        .into());
    }
    let replacement = requests::prepare_source_reassignment(
        &execution,
        &attempt,
        predecessor,
        trust,
        &canonical_now(),
    )?;
    Ok(ReassignmentContext {
        execution,
        attempt,
        replacement,
    })
}

async fn exact_outbound_upload(
    db: &AsyncDaemonDb,
    assignment: &TaskBoardRemoteAssignmentRecord,
    offer: &RemoteOfferRequest,
) -> Result<RemoteSourceBundleUploadRequest, CliError> {
    let request = db
        .task_board_remote_outbound_source_upload(
            &assignment.assignment_id,
            assignment.fencing_epoch,
        )
        .await?
        .ok_or_else(|| {
            CliErrorKind::concurrent_modification(
                "remote outbound source bytes disappeared before upload",
            )
        })?;
    if request.offer == *offer {
        Ok(request)
    } else {
        Err(CliErrorKind::concurrent_modification(
            "remote outbound source changed from its sealed offer",
        )
        .into())
    }
}

fn reassignment_progressed(outcome: &TaskBoardRemoteOfferOutcome) -> bool {
    matches!(
        outcome,
        TaskBoardRemoteOfferOutcome::Created(_) | TaskBoardRemoteOfferOutcome::Replayed(_)
    )
}
