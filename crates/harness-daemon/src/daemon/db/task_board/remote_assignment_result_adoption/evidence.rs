use sqlx::{Sqlite, Transaction, query_scalar};

use crate::daemon::db::task_board::remote_artifacts::{
    TaskBoardRemoteArtifact, load_artifact_in_tx,
};
use crate::daemon::db::task_board::remote_assignment_executor_terminal::{
    REMOTE_IMPLEMENTATION_BUNDLE_MEDIA_TYPE, REMOTE_IMPLEMENTATION_BUNDLE_PATH,
    REMOTE_RESULT_ARTIFACT_MEDIA_TYPE, REMOTE_RESULT_ARTIFACT_PATH,
};
use crate::daemon::db::task_board::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, concurrent, to_i64,
};
use crate::daemon::db::task_board::remote_result_import::load_and_finalize_remote_implementation_import_in_tx;
use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{RemoteArtifactEntry, RemoteTypedResult};
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase,
    TaskBoardWorkflowExecutionRecord, task_board_local_attempt_result_expectation,
    validate_task_board_local_attempt_result,
};

pub(super) async fn load_completed_artifact(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    adopted_at: &str,
) -> Result<TaskBoardAttemptResultArtifact, CliError> {
    let response = assignment
        .status_response
        .as_ref()
        .ok_or_else(|| concurrent("completed remote assignment has no status"))?;
    let typed = response
        .result
        .as_ref()
        .ok_or_else(|| concurrent("completed remote assignment has no typed result"))?;
    let entries = &response.output_artifacts.entries;
    require_completed_manifest(assignment.phase, entries)?;
    require_artifact_count(transaction, assignment, entries.len()).await?;
    let stored_result = load_exact_artifact(transaction, assignment, &entries[0]).await?;
    let parsed = serde_json::from_slice::<RemoteTypedResult>(&stored_result.content)
        .map_err(|error| db_error(format!("parse fetched remote result: {error}")))?;
    if parsed != *typed {
        return Err(concurrent(
            "fetched remote result differs from provisional terminal evidence",
        ));
    }
    let offer = assignment.require_offer()?;
    parsed
        .validate(&offer.binding, &offer.request_sha256)
        .map_err(|error| db_error(format!("validate fetched remote result: {error}")))?;
    let expected = task_board_local_attempt_result_expectation(parent, attempt)
        .map_err(|_| db_error("remote result has no frozen local result contract"))?;
    validate_task_board_local_attempt_result(&parsed.result, &expected)
        .map_err(|_| concurrent("remote result contradicts the frozen workflow attempt"))?;
    if matches!(
        &parsed.result.artifact,
        TaskBoardAttemptResultArtifact::Implementation(_)
    ) {
        load_and_finalize_remote_implementation_import_in_tx(
            transaction,
            assignment,
            parent,
            attempt,
            &parsed,
            entries,
            adopted_at,
        )
        .await?;
    }
    Ok(parsed.result.artifact)
}

pub(super) async fn require_failed_artifact_set(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Result<(), CliError> {
    let response = assignment
        .status_response
        .as_ref()
        .ok_or_else(|| concurrent("failed remote assignment has no status"))?;
    if response.result.is_some() || !response.output_artifacts.entries.is_empty() {
        return Err(concurrent(
            "failed remote assignment cannot adopt result artifacts",
        ));
    }
    require_artifact_count(transaction, assignment, 0).await
}

fn require_completed_manifest(
    phase: TaskBoardExecutionPhase,
    entries: &[RemoteArtifactEntry],
) -> Result<(), CliError> {
    let result = entries.first().is_some_and(|entry| {
        entry.relative_path == REMOTE_RESULT_ARTIFACT_PATH
            && entry.media_type == REMOTE_RESULT_ARTIFACT_MEDIA_TYPE
    });
    let exact = match phase {
        TaskBoardExecutionPhase::Implementation => {
            result
                && entries.len() == 2
                && entries[1].relative_path == REMOTE_IMPLEMENTATION_BUNDLE_PATH
                && entries[1].media_type == REMOTE_IMPLEMENTATION_BUNDLE_MEDIA_TYPE
        }
        TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate => {
            result && entries.len() == 1
        }
        _ => false,
    };
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "remote result manifest differs from its phase-required artifact set",
        ))
    }
}

async fn load_exact_artifact(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    entry: &RemoteArtifactEntry,
) -> Result<TaskBoardRemoteArtifact, CliError> {
    let artifact = load_artifact_in_tx(
        transaction,
        &assignment.assignment_id,
        assignment.fencing_epoch,
        &entry.relative_path,
    )
    .await?
    .ok_or_else(|| concurrent("remote result manifest artifact is not durably fetched"))?;
    let offer = assignment.require_offer()?;
    let exact = artifact.artifact == *entry
        && assignment.lease_id.as_deref() == Some(artifact.lease_id.as_str())
        && artifact.offer_request_sha256 == offer.request_sha256
        && assignment.authenticated_principal.as_deref()
            == Some(artifact.authenticated_principal.as_str());
    if exact {
        Ok(artifact)
    } else {
        Err(concurrent(
            "fetched remote artifact changed its assignment generation evidence",
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
        "result adoption fencing epoch",
    )?)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("count fetched remote artifacts: {error}")))?;
    if usize::try_from(count).ok() == Some(expected) {
        Ok(())
    } else {
        Err(concurrent(
            "fetched remote artifact set differs from the terminal manifest",
        ))
    }
}
