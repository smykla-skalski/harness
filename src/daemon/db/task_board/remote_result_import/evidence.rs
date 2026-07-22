use sqlx::{Sqlite, Transaction, query_scalar};

use super::model::TaskBoardRemoteResultImportRequest;
use super::super::remote_artifacts::{TaskBoardRemoteArtifact, load_artifact_in_tx};
use super::super::remote_assignment_executor_terminal::{
    REMOTE_IMPLEMENTATION_BUNDLE_MEDIA_TYPE, REMOTE_IMPLEMENTATION_BUNDLE_PATH,
    REMOTE_RESULT_ARTIFACT_MEDIA_TYPE, REMOTE_RESULT_ARTIFACT_PATH,
};
use super::super::remote_assignment_io_authority::active_target_matches;
use super::super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, concurrent, to_i64,
};
use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteTypedResult,
};
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionPhase, TaskBoardExecutionState, TaskBoardWorkflowExecutionRecord,
    task_board_local_attempt_result_expectation, validate_task_board_local_attempt_result,
};

pub(super) struct ImportMaterials {
    pub(super) typed: RemoteTypedResult,
    pub(super) result_artifact: TaskBoardRemoteArtifact,
    pub(super) bundle_artifact: TaskBoardRemoteArtifact,
}

pub(super) async fn load_import_materials(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
    request: &TaskBoardRemoteResultImportRequest,
) -> Result<ImportMaterials, CliError> {
    let attempt = exact_import_attempt(assignment, parent)?;
    require_import_target(assignment, parent, attempt, request)?;
    let response = assignment
        .status_response
        .as_ref()
        .ok_or_else(|| concurrent("remote result import has no terminal status evidence"))?;
    let typed = response
        .result
        .clone()
        .ok_or_else(|| concurrent("remote result import has no typed result evidence"))?;
    let offer = assignment.require_offer()?;
    typed
        .validate(&offer.binding, &offer.request_sha256)
        .map_err(|_| concurrent("remote import typed result is invalid"))?;
    let expected = task_board_local_attempt_result_expectation(parent, attempt)
        .map_err(|_| concurrent("remote import has no frozen local result contract"))?;
    validate_task_board_local_attempt_result(&typed.result, &expected)
        .map_err(|_| concurrent("remote import result contradicts its frozen attempt"))?;
    let TaskBoardAttemptResultArtifact::Implementation(result) = &typed.result.artifact else {
        return Err(concurrent(
            "remote result import accepts only implementation evidence",
        ));
    };
    if request.base_revision != result.base_head_revision
        || request.result_revision != result.head_revision
        || assignment.status_sha256.as_deref() != Some(response.status_sha256.as_str())
        || assignment.result_sha256.as_deref() != Some(typed.result_sha256.as_str())
    {
        return Err(concurrent(
            "remote result import revisions or terminal digests changed",
        ));
    }
    require_manifest(response)?;
    require_artifact_count(transaction, assignment, 2).await?;
    let result_artifact = load_exact_artifact(
        transaction,
        assignment,
        REMOTE_RESULT_ARTIFACT_PATH,
    )
    .await?;
    let bundle_artifact = load_exact_artifact(
        transaction,
        assignment,
        REMOTE_IMPLEMENTATION_BUNDLE_PATH,
    )
    .await?;
    let parsed = serde_json::from_slice::<RemoteTypedResult>(&result_artifact.content)
        .map_err(|_| concurrent("fetched remote result bytes are invalid"))?;
    if parsed != typed {
        return Err(concurrent(
            "fetched result bytes differ from provisional terminal evidence",
        ));
    }
    Ok(ImportMaterials {
        typed,
        result_artifact,
        bundle_artifact,
    })
}

pub(super) fn exact_import_attempt<'a>(
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &'a TaskBoardWorkflowExecutionRecord,
) -> Result<&'a TaskBoardExecutionAttemptRecord, CliError> {
    let offer = assignment.require_offer()?;
    parent
        .attempts
        .iter()
        .find(|attempt| {
            attempt.action_key == offer.binding.action_key
                && attempt.attempt == offer.binding.attempt
                && attempt.idempotency_key == offer.binding.idempotency_key
        })
        .ok_or_else(|| concurrent("remote result import exact attempt disappeared"))
}

fn require_import_target(
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    request: &TaskBoardRemoteResultImportRequest,
) -> Result<(), CliError> {
    let run_context = parent
        .snapshot
        .read_only_run_context
        .as_ref()
        .ok_or_else(|| db_error("remote result import has no frozen run context"))?;
    let expected_branch = format!("refs/heads/harness/{}", run_context.session_id);
    let exact = assignment.state == crate::task_board::TaskBoardRemoteAssignmentState::Completed
        && assignment.phase == TaskBoardExecutionPhase::Implementation
        && assignment.fencing_epoch == request.fencing_epoch
        && assignment.assignment_id == request.assignment_id
        && active_target_matches(parent, assignment)
        && matches!(
            parent.transition.execution_state,
            TaskBoardExecutionState::Starting | TaskBoardExecutionState::Running
        )
        && matches!(
            attempt.state,
            TaskBoardAttemptState::Starting | TaskBoardAttemptState::Running
        )
        && run_context.worktree == request.worktree_path
        && request.branch_ref == expected_branch;
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "remote result import lost its exact active worktree target",
        ))
    }
}

fn require_manifest(
    response: &crate::daemon::task_board_remote_transport::wire::RemoteStatusResponse,
) -> Result<(), CliError> {
    let entries = &response.output_artifacts.entries;
    let exact = response.state == RemoteAssignmentWireState::Completed
        && entries.len() == 2
        && entries[0].relative_path == REMOTE_RESULT_ARTIFACT_PATH
        && entries[0].media_type == REMOTE_RESULT_ARTIFACT_MEDIA_TYPE
        && entries[1].relative_path == REMOTE_IMPLEMENTATION_BUNDLE_PATH
        && entries[1].media_type == REMOTE_IMPLEMENTATION_BUNDLE_MEDIA_TYPE;
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "remote result import manifest is not the exact implementation artifact set",
        ))
    }
}

async fn load_exact_artifact(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    relative_path: &str,
) -> Result<TaskBoardRemoteArtifact, CliError> {
    let artifact = load_artifact_in_tx(
        transaction,
        &assignment.assignment_id,
        assignment.fencing_epoch,
        relative_path,
    )
    .await?
    .ok_or_else(|| concurrent("remote result import artifact was not durably fetched"))?;
    let offer = assignment.require_offer()?;
    let expected = assignment
        .status_response
        .as_ref()
        .and_then(|status| {
            status
                .output_artifacts
                .entries
                .iter()
                .find(|entry| entry.relative_path == relative_path)
        })
        .ok_or_else(|| concurrent("remote result import artifact left its manifest"))?;
    let exact = artifact.artifact == *expected
        && assignment.lease_id.as_deref() == Some(artifact.lease_id.as_str())
        && artifact.offer_request_sha256 == offer.request_sha256
        && assignment.authenticated_principal.as_deref()
            == Some(artifact.authenticated_principal.as_str());
    if exact {
        Ok(artifact)
    } else {
        Err(concurrent(
            "remote result import artifact changed its assignment evidence",
        ))
    }
}

async fn require_artifact_count(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    expected: usize,
) -> Result<(), CliError> {
    let count = query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM task_board_remote_artifacts
         WHERE assignment_id = ?1 AND fencing_epoch = ?2",
    )
    .bind(&assignment.assignment_id)
    .bind(to_i64(
        assignment.fencing_epoch,
        "remote result import artifact epoch",
    )?)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("count remote import artifacts: {error}")))?;
    if usize::try_from(count).ok() == Some(expected) {
        Ok(())
    } else {
        Err(concurrent(
            "remote result import artifact count changed from its manifest",
        ))
    }
}
