//! Preparing a remote result import: loading the exact records it must match,
//! then either replaying the import already stored for them or storing a new
//! one. `remote_result_import.rs` owns the transaction and commits once.

use sqlx::{Sqlite, Transaction};

use super::super::ORCHESTRATOR_CHANGE_SCOPE;
use super::super::items::bump_change_in_tx;
use super::super::remote_assignment_io_authority::monotonic_time;
use super::super::remote_assignment_model::{TaskBoardRemoteAssignmentRecord, concurrent};
use super::super::workflow_executions::{
    cas_mismatch, load_execution_in_tx, update_execution_in_tx,
};
use super::evidence::{ImportMaterials, load_import_materials};
use super::model::{TaskBoardRemoteResultImportRecord, TaskBoardRemoteResultImportRequest};
use super::storage::{insert_import_in_tx, load_import_in_tx, prepared_import};
use super::{exact_assignment, require_exact_replay, require_import_authority_available};
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord, validate_task_board_workflow_execution,
};

/// The exact records a result import is prepared against, all read under the
/// same transaction. The parent execution still has to match the caller's CAS.
pub(super) struct LoadedResultImport {
    pub(super) assignment: TaskBoardRemoteAssignmentRecord,
    pub(super) parent: TaskBoardWorkflowExecutionRecord,
    pub(super) materials: ImportMaterials,
}

/// Loads the assignment, its parent execution and the import materials, and
/// refuses an execution that moved away from `expected` before any of it is
/// stored.
pub(super) async fn load_result_import_target_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &TaskBoardWorkflowExecutionCas,
    request: &TaskBoardRemoteResultImportRequest,
) -> Result<Box<LoadedResultImport>, CliError> {
    let assignment = exact_assignment(transaction, request).await?;
    let parent = load_execution_in_tx(transaction, &assignment.execution_id)
        .await?
        .ok_or_else(|| concurrent("remote result import execution disappeared"))?;
    if cas_mismatch(expected, &parent).is_some() {
        return Err(concurrent(
            "remote result import lost its exact parent record",
        ));
    }
    let materials = load_import_materials(transaction, &assignment, &parent, request).await?;
    Ok(Box::new(LoadedResultImport {
        assignment,
        parent,
        materials,
    }))
}

/// Reports the import to hand back and the commit's error context. An import
/// already stored for this exact assignment generation is replayed rather than
/// rewritten, and only if it matches what this call would have stored.
pub(super) async fn resolve_result_import_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &TaskBoardWorkflowExecutionCas,
    request: &TaskBoardRemoteResultImportRequest,
    loaded: &LoadedResultImport,
) -> Result<(TaskBoardRemoteResultImportRecord, &'static str), CliError> {
    let stored = load_import_in_tx(
        transaction,
        &loaded.assignment.assignment_id,
        loaded.assignment.fencing_epoch,
    )
    .await?;
    match stored {
        Some(existing) => {
            require_exact_replay(
                &existing,
                request,
                &loaded.assignment,
                &loaded.parent,
                &loaded.materials,
            )?;
            Ok((existing, "replayed result import"))
        }
        None => Ok((
            store_prepared_import_in_tx(transaction, expected, request, loaded).await?,
            "prepared result import",
        )),
    }
}

/// Stores the import and takes the parent execution's import authority for it,
/// which is what stops a second importer preparing the same result.
async fn store_prepared_import_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &TaskBoardWorkflowExecutionCas,
    request: &TaskBoardRemoteResultImportRequest,
    loaded: &LoadedResultImport,
) -> Result<TaskBoardRemoteResultImportRecord, CliError> {
    require_import_authority_available(&loaded.assignment, &loaded.parent)?;
    let prepared = prepared_import(request, &loaded.assignment, &loaded.materials, expected)?;
    let mut updated_parent = loaded.parent.clone();
    updated_parent.ownership.resources.insert(
        TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE.into(),
        prepared.import_sha256.clone(),
    );
    updated_parent.updated_at = monotonic_time(&loaded.parent.updated_at, &request.prepared_at)?;
    validate_task_board_workflow_execution(&updated_parent)
        .map_err(|error| db_error(format!("validate result import authority: {error}")))?;
    let record = prepared.into_record(&updated_parent);
    insert_import_in_tx(transaction, &record).await?;
    update_execution_in_tx(
        transaction,
        &TaskBoardWorkflowExecutionCas::from(&loaded.parent),
        &updated_parent,
    )
    .await?;
    bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    Ok(record)
}
