use sqlx::{Sqlite, Transaction, query};

use super::evidence::load_import_materials;
use super::model::{
    TaskBoardRemoteImplementationImportEvidence, TaskBoardRemoteResultImportState,
};
use super::storage::load_import_in_tx;
use super::require_record_materials;
use crate::daemon::db::task_board::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, canonical_time, concurrent, to_i64,
};
use crate::daemon::db::{CliError, db_error};
use crate::task_board::remote_wire::wire::{RemoteArtifactEntry, RemoteTypedResult};
use crate::task_board::{
    TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE, TaskBoardAttemptResultArtifact,
    TaskBoardExecutionAttemptRecord, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord,
};

pub(in crate::daemon::db::task_board) async fn load_and_finalize_remote_implementation_import_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    typed: &RemoteTypedResult,
    entries: &[RemoteArtifactEntry],
    adopted_at: &str,
) -> Result<TaskBoardRemoteImplementationImportEvidence, CliError> {
    let adopted_time = canonical_time(adopted_at, "remote result import adoption time")?;
    let record = load_import_in_tx(
        transaction,
        &assignment.assignment_id,
        assignment.fencing_epoch,
    )
    .await?
    .ok_or_else(|| concurrent("remote result import journal is missing"))?;
    let applied_time = record
        .applied_at
        .as_deref()
        .ok_or_else(|| concurrent("remote result import has no applied timestamp"))?;
    if adopted_time < canonical_time(applied_time, "remote result import applied time")? {
        return Err(db_error(
            "remote result import adoption time precedes Git application",
        ));
    }
    if record.state != TaskBoardRemoteResultImportState::Applied
        || TaskBoardWorkflowExecutionCas::from(parent).record_sha256 != record.parent_record_sha256
        || parent
            .ownership
            .resources
            .get(TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE)
            != Some(&record.import_sha256)
        || attempt.action_key != record.action_key
        || attempt.attempt != record.attempt
        || attempt.idempotency_key != record.idempotency_key
    {
        return Err(concurrent(
            "remote result import lost its exact parent and attempt authority",
        ));
    }
    let request = record.request();
    let materials = load_import_materials(transaction, assignment, parent, &request).await?;
    require_record_materials(&record, assignment, &materials)?;
    if materials.typed != *typed
        || entries.len() != 2
        || entries[0] != materials.result_artifact.artifact
        || entries[1] != materials.bundle_artifact.artifact
        || materials.result_artifact.artifact.sha256 != record.result_artifact_sha256
        || materials.bundle_artifact.artifact.sha256 != record.bundle_sha256
    {
        return Err(concurrent(
            "remote result import adoption evidence changed after Git application",
        ));
    }
    let rows = query(
        "UPDATE task_board_remote_result_imports
         SET state = 'adopted', adopted_at = ?1
         WHERE assignment_id = ?2 AND fencing_epoch = ?3
           AND import_sha256 = ?4 AND state = 'applied'",
    )
    .bind(adopted_at)
    .bind(&record.assignment_id)
    .bind(to_i64(
        record.fencing_epoch,
        "result import adoption epoch",
    )?)
    .bind(&record.import_sha256)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("finalize remote result import: {error}")))?
    .rows_affected();
    if rows != 1 {
        return Err(concurrent(
            "remote result import changed before final adoption",
        ));
    }
    Ok(record.evidence())
}

pub(in crate::daemon::db::task_board) async fn require_adopted_remote_implementation_import_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Result<(), CliError> {
    let record = load_import_in_tx(
        transaction,
        &assignment.assignment_id,
        assignment.fencing_epoch,
    )
    .await?
    .ok_or_else(|| concurrent("adopted implementation import journal is missing"))?;
    let offer = assignment.require_offer()?;
    let status = assignment
        .status_response
        .as_ref()
        .ok_or_else(|| concurrent("adopted implementation terminal status is missing"))?;
    let typed = status
        .result
        .as_ref()
        .ok_or_else(|| concurrent("adopted implementation typed result is missing"))?;
    let TaskBoardAttemptResultArtifact::Implementation(result) = &typed.result.artifact else {
        return Err(concurrent(
            "adopted implementation import changed its result kind",
        ));
    };
    let exact = record.state == TaskBoardRemoteResultImportState::Adopted
        && record.execution_id == assignment.execution_id
        && record.action_key == offer.binding.action_key
        && record.attempt == offer.binding.attempt
        && record.idempotency_key == offer.binding.idempotency_key
        && record.offer_request_sha256 == offer.request_sha256
        && record.status_sha256 == status.status_sha256
        && record.result_sha256 == typed.result_sha256
        && record.base_revision == result.base_head_revision
        && record.result_revision == result.head_revision;
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "adopted implementation import replay changed immutable evidence",
        ))
    }
}
