use serde::Serialize;
use sha2::{Digest, Sha256};
use sqlx::{Sqlite, Transaction, query, query_as};

use super::evidence::ImportMaterials;
use super::model::{
    RemoteResultImportRow, TaskBoardRemoteResultImportRecord, TaskBoardRemoteResultImportRequest,
    TaskBoardRemoteResultImportState,
};
use super::super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, concurrent, to_i64,
};
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord};

#[derive(Serialize)]
struct PreparedImportDigest<'a> {
    request: &'a TaskBoardRemoteResultImportRequest,
    execution_id: &'a str,
    action_key: &'a str,
    attempt: u32,
    idempotency_key: &'a str,
    offer_request_sha256: &'a str,
    status_sha256: &'a str,
    result_sha256: &'a str,
    result_artifact_sha256: &'a str,
    bundle_sha256: &'a str,
    expected_parent_sha256: &'a str,
}

pub(super) struct PreparedImport {
    request: TaskBoardRemoteResultImportRequest,
    execution_id: String,
    action_key: String,
    attempt: u32,
    idempotency_key: String,
    offer_request_sha256: String,
    status_sha256: String,
    result_sha256: String,
    result_artifact_sha256: String,
    bundle_sha256: String,
    pub(super) import_sha256: String,
}

impl PreparedImport {
    pub(super) fn into_record(
        self,
        updated_parent: &TaskBoardWorkflowExecutionRecord,
    ) -> TaskBoardRemoteResultImportRecord {
        TaskBoardRemoteResultImportRecord {
            assignment_id: self.request.assignment_id,
            fencing_epoch: self.request.fencing_epoch,
            execution_id: self.execution_id,
            action_key: self.action_key,
            attempt: self.attempt,
            idempotency_key: self.idempotency_key,
            offer_request_sha256: self.offer_request_sha256,
            status_sha256: self.status_sha256,
            result_sha256: self.result_sha256,
            result_artifact_sha256: self.result_artifact_sha256,
            bundle_sha256: self.bundle_sha256,
            parent_record_sha256: TaskBoardWorkflowExecutionCas::from(updated_parent).record_sha256,
            worktree_path: self.request.worktree_path,
            git_dir: self.request.git_dir,
            common_git_dir: self.request.common_git_dir,
            branch_ref: self.request.branch_ref,
            base_revision: self.request.base_revision,
            result_revision: self.request.result_revision,
            advertised_ref: self.request.advertised_ref,
            import_ref: self.request.import_ref,
            object_format: self.request.object_format,
            import_sha256: self.import_sha256,
            state: TaskBoardRemoteResultImportState::Prepared,
            prepared_at: self.request.prepared_at,
            applied_at: None,
            adopted_at: None,
            last_error: None,
        }
    }
}

pub(super) fn prepared_import(
    request: &TaskBoardRemoteResultImportRequest,
    assignment: &TaskBoardRemoteAssignmentRecord,
    materials: &ImportMaterials,
    expected: &TaskBoardWorkflowExecutionCas,
) -> Result<PreparedImport, CliError> {
    let offer = assignment.require_offer()?;
    let status = assignment
        .status_response
        .as_ref()
        .ok_or_else(|| concurrent("remote result import status disappeared"))?;
    let digest = PreparedImportDigest {
        request,
        execution_id: &assignment.execution_id,
        action_key: &offer.binding.action_key,
        attempt: offer.binding.attempt,
        idempotency_key: &offer.binding.idempotency_key,
        offer_request_sha256: &offer.request_sha256,
        status_sha256: &status.status_sha256,
        result_sha256: &materials.typed.result_sha256,
        result_artifact_sha256: &materials.result_artifact.artifact.sha256,
        bundle_sha256: &materials.bundle_artifact.artifact.sha256,
        expected_parent_sha256: &expected.record_sha256,
    };
    let bytes = serde_json::to_vec(&("harness.task-board.remote-result-import.v1", digest))
        .map_err(|error| db_error(format!("seal remote result import: {error}")))?;
    Ok(PreparedImport {
        request: request.clone(),
        execution_id: assignment.execution_id.clone(),
        action_key: offer.binding.action_key.clone(),
        attempt: offer.binding.attempt,
        idempotency_key: offer.binding.idempotency_key.clone(),
        offer_request_sha256: offer.request_sha256.clone(),
        status_sha256: status.status_sha256.clone(),
        result_sha256: materials.typed.result_sha256.clone(),
        result_artifact_sha256: materials.result_artifact.artifact.sha256.clone(),
        bundle_sha256: materials.bundle_artifact.artifact.sha256.clone(),
        import_sha256: hex::encode(Sha256::digest(bytes)),
    })
}

pub(super) async fn load_import_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment_id: &str,
    fencing_epoch: u64,
) -> Result<Option<TaskBoardRemoteResultImportRecord>, CliError> {
    query_as::<_, RemoteResultImportRow>(RemoteResultImportRow::SELECT)
        .bind(assignment_id)
        .bind(to_i64(fencing_epoch, "result import load epoch")?)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load remote result import: {error}")))?
        .map(RemoteResultImportRow::into_record)
        .transpose()
}

pub(super) async fn require_import(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment_id: &str,
    fencing_epoch: u64,
    import_sha256: &str,
) -> Result<TaskBoardRemoteResultImportRecord, CliError> {
    let record = load_import_in_tx(transaction, assignment_id, fencing_epoch)
        .await?
        .ok_or_else(|| concurrent("remote result import journal disappeared"))?;
    if record.import_sha256 == import_sha256 {
        Ok(record)
    } else {
        Err(concurrent("remote result import digest changed"))
    }
}

pub(super) async fn insert_import_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteResultImportRecord,
) -> Result<(), CliError> {
    query(
        "INSERT INTO task_board_remote_result_imports (
           assignment_id, fencing_epoch, execution_id, action_key, attempt,
           idempotency_key, offer_request_sha256, status_sha256, result_sha256,
           result_artifact_sha256, bundle_sha256, parent_record_sha256,
           worktree_path, git_dir, common_git_dir, branch_ref, base_revision, result_revision,
           advertised_ref, import_ref, object_format, import_sha256, state, prepared_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                   ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, 'prepared', ?23)",
    )
    .bind(&record.assignment_id)
    .bind(to_i64(record.fencing_epoch, "result import insert epoch")?)
    .bind(&record.execution_id)
    .bind(&record.action_key)
    .bind(i64::from(record.attempt))
    .bind(&record.idempotency_key)
    .bind(&record.offer_request_sha256)
    .bind(&record.status_sha256)
    .bind(&record.result_sha256)
    .bind(&record.result_artifact_sha256)
    .bind(&record.bundle_sha256)
    .bind(&record.parent_record_sha256)
    .bind(&record.worktree_path)
    .bind(&record.git_dir)
    .bind(&record.common_git_dir)
    .bind(&record.branch_ref)
    .bind(&record.base_revision)
    .bind(&record.result_revision)
    .bind(&record.advertised_ref)
    .bind(&record.import_ref)
    .bind(&record.object_format)
    .bind(&record.import_sha256)
    .bind(&record.prepared_at)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("insert remote result import: {error}")))
}
