use sqlx::{Sqlite, Transaction, query};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_io_authority::{active_target_matches, has_remote_io_authority};
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, canonical_time, concurrent, load_assignment_in_tx, to_i64,
};
use super::workflow_executions::{cas_mismatch, load_execution_in_tx, update_execution_in_tx};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{RemoteArtifactEntry, RemoteTypedResult};
use crate::git::bundle::GitBundleImportEvidence;
use crate::task_board::{
    TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE, TaskBoardExecutionAttemptRecord,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
    validate_task_board_workflow_execution,
};

#[path = "remote_result_import/evidence.rs"]
mod evidence;
#[path = "remote_result_import/failure.rs"]
mod failure;
#[path = "remote_result_import/model.rs"]
mod model;
#[path = "remote_result_import/storage.rs"]
mod storage;
use evidence::{ImportMaterials, load_import_materials};
pub(crate) use model::{
    TaskBoardRemoteImplementationImportEvidence, TaskBoardRemoteResultImportRecord,
    TaskBoardRemoteResultImportRequest, TaskBoardRemoteResultImportState,
    TaskBoardRemoteResultImportWork,
};
use storage::{insert_import_in_tx, load_import_in_tx, prepared_import, require_import};

impl AsyncDaemonDb {
    pub(crate) async fn prepare_task_board_remote_result_import(
        &self,
        expected: &TaskBoardWorkflowExecutionCas,
        request: &TaskBoardRemoteResultImportRequest,
    ) -> Result<TaskBoardRemoteResultImportWork, CliError> {
        request.validate()?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote result import prepare")
            .await?;
        let assignment = exact_assignment(&mut transaction, request).await?;
        let parent = load_execution_in_tx(&mut transaction, &assignment.execution_id)
            .await?
            .ok_or_else(|| concurrent("remote result import execution disappeared"))?;
        if cas_mismatch(expected, &parent).is_some() {
            return Err(concurrent(
                "remote result import lost its exact parent record",
            ));
        }
        let materials =
            load_import_materials(&mut transaction, &assignment, &parent, request).await?;
        if let Some(existing) = load_import_in_tx(
            &mut transaction,
            &assignment.assignment_id,
            assignment.fencing_epoch,
        )
        .await?
        {
            require_exact_replay(&existing, request, &assignment, &parent, &materials)?;
            transaction
                .commit()
                .await
                .map_err(|error| db_error(format!("commit replayed result import: {error}")))?;
            return Ok(TaskBoardRemoteResultImportWork {
                record: existing,
                bundle: materials.bundle_artifact.content,
            });
        }
        require_import_authority_available(&assignment, &parent)?;
        let prepared = prepared_import(request, &assignment, &materials, expected)?;
        let mut updated_parent = parent.clone();
        updated_parent.ownership.resources.insert(
            TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE.into(),
            prepared.import_sha256.clone(),
        );
        updated_parent.updated_at = super::remote_assignment_io_authority::monotonic_time(
            &parent.updated_at,
            &request.prepared_at,
        )?;
        validate_task_board_workflow_execution(&updated_parent)
            .map_err(|error| db_error(format!("validate result import authority: {error}")))?;
        let record = prepared.into_record(&updated_parent);
        insert_import_in_tx(&mut transaction, &record).await?;
        update_execution_in_tx(
            &mut transaction,
            &TaskBoardWorkflowExecutionCas::from(&parent),
            &updated_parent,
        )
        .await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit prepared result import: {error}")))?;
        Ok(TaskBoardRemoteResultImportWork {
            record,
            bundle: materials.bundle_artifact.content,
        })
    }

    pub(crate) async fn record_task_board_remote_result_import_applied(
        &self,
        assignment_id: &str,
        fencing_epoch: u64,
        import_sha256: &str,
        git: &GitBundleImportEvidence,
        applied_at: &str,
    ) -> Result<TaskBoardRemoteResultImportRecord, CliError> {
        let applied_time = canonical_time(applied_at, "remote result import applied time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote result import applied")
            .await?;
        let record = require_import(
            &mut transaction,
            assignment_id,
            fencing_epoch,
            import_sha256,
        )
        .await?;
        if applied_time < canonical_time(&record.prepared_at, "remote result import prepared time")?
        {
            return Err(db_error(
                "remote result import applied time precedes its preparation",
            ));
        }
        require_git_evidence(&record, git)?;
        require_import_authority(&mut transaction, &record).await?;
        if record.state == TaskBoardRemoteResultImportState::Applied {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit replayed applied result import: {error}"))
            })?;
            return Ok(record);
        }
        if record.state != TaskBoardRemoteResultImportState::Prepared {
            return Err(concurrent(
                "remote result import cannot advance from its durable state",
            ));
        }
        let rows = query(
            "UPDATE task_board_remote_result_imports
             SET state = 'applied', applied_at = ?1
             WHERE assignment_id = ?2 AND fencing_epoch = ?3
               AND import_sha256 = ?4 AND state = 'prepared'",
        )
        .bind(applied_at)
        .bind(assignment_id)
        .bind(to_i64(fencing_epoch, "result import applied epoch")?)
        .bind(import_sha256)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("persist applied result import: {error}")))?
        .rows_affected();
        if rows != 1 {
            return Err(concurrent(
                "remote result import changed before applied evidence was persisted",
            ));
        }
        let updated = require_import(
            &mut transaction,
            assignment_id,
            fencing_epoch,
            import_sha256,
        )
        .await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit applied result import: {error}")))?;
        Ok(updated)
    }

    pub(crate) async fn task_board_remote_result_import(
        &self,
        assignment_id: &str,
        fencing_epoch: u64,
    ) -> Result<Option<TaskBoardRemoteResultImportRecord>, CliError> {
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin result import load: {error}")))?;
        let record = load_import_in_tx(&mut transaction, assignment_id, fencing_epoch).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit result import load: {error}")))?;
        Ok(record)
    }

    pub(crate) async fn mark_task_board_remote_result_import_manual_required(
        &self,
        assignment_id: &str,
        fencing_epoch: u64,
        import_sha256: &str,
        detail: &str,
        failed_at: &str,
    ) -> Result<TaskBoardRemoteResultImportRecord, CliError> {
        failure::mark_manual_required(
            self,
            assignment_id,
            fencing_epoch,
            import_sha256,
            detail,
            failed_at,
        )
        .await
    }
}

pub(super) async fn load_and_finalize_remote_implementation_import_in_tx(
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

pub(super) async fn require_adopted_remote_implementation_import_in_tx(
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
    let crate::task_board::TaskBoardAttemptResultArtifact::Implementation(result) =
        &typed.result.artifact
    else {
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

async fn exact_assignment(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &TaskBoardRemoteResultImportRequest,
) -> Result<TaskBoardRemoteAssignmentRecord, CliError> {
    let assignment = load_assignment_in_tx(transaction, &request.assignment_id)
        .await?
        .ok_or_else(|| concurrent("remote result import assignment disappeared"))?;
    if assignment.fencing_epoch == request.fencing_epoch {
        Ok(assignment)
    } else {
        Err(concurrent(
            "remote result import assignment generation changed",
        ))
    }
}

fn require_import_authority_available(
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), CliError> {
    if assignment.controller_operation.is_none()
        && assignment.executor_start_authority_sha256.is_none()
        && assignment.executor_stop_pending.is_none()
        && !has_remote_io_authority(parent)
        && active_target_matches(parent, assignment)
    {
        Ok(())
    } else {
        Err(concurrent(
            "remote result import conflicts with another durable authority",
        ))
    }
}

fn require_exact_replay(
    record: &TaskBoardRemoteResultImportRecord,
    request: &TaskBoardRemoteResultImportRequest,
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
    materials: &ImportMaterials,
) -> Result<(), CliError> {
    let offer = assignment.require_offer()?;
    require_record_materials(record, assignment, materials)?;
    let exact = record.assignment_id == request.assignment_id
        && record.fencing_epoch == request.fencing_epoch
        && record.execution_id == assignment.execution_id
        && record.action_key == offer.binding.action_key
        && record.attempt == offer.binding.attempt
        && record.idempotency_key == offer.binding.idempotency_key
        && record.worktree_path == request.worktree_path
        && record.git_dir == request.git_dir
        && record.common_git_dir == request.common_git_dir
        && record.branch_ref == request.branch_ref
        && record.base_revision == request.base_revision
        && record.result_revision == request.result_revision
        && record.advertised_ref == request.advertised_ref
        && record.import_ref == request.import_ref
        && record.object_format == request.object_format
        && TaskBoardWorkflowExecutionCas::from(parent).record_sha256 == record.parent_record_sha256
        && parent
            .ownership
            .resources
            .get(TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE)
            == Some(&record.import_sha256);
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "remote result import replay changed immutable evidence",
        ))
    }
}

fn require_record_materials(
    record: &TaskBoardRemoteResultImportRecord,
    assignment: &TaskBoardRemoteAssignmentRecord,
    materials: &ImportMaterials,
) -> Result<(), CliError> {
    let offer = assignment.require_offer()?;
    let status = assignment
        .status_response
        .as_ref()
        .ok_or_else(|| concurrent("remote result import status disappeared"))?;
    let exact = record.assignment_id == assignment.assignment_id
        && record.fencing_epoch == assignment.fencing_epoch
        && record.execution_id == assignment.execution_id
        && record.action_key == offer.binding.action_key
        && record.attempt == offer.binding.attempt
        && record.idempotency_key == offer.binding.idempotency_key
        && record.offer_request_sha256 == offer.request_sha256
        && record.status_sha256 == status.status_sha256
        && record.result_sha256 == materials.typed.result_sha256
        && record.result_artifact_sha256 == materials.result_artifact.artifact.sha256
        && record.bundle_sha256 == materials.bundle_artifact.artifact.sha256;
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "remote result import assignment or artifact evidence changed",
        ))
    }
}

fn require_git_evidence(
    record: &TaskBoardRemoteResultImportRecord,
    git: &GitBundleImportEvidence,
) -> Result<(), CliError> {
    let exact = record.worktree_path == git.worktree_path
        && record.git_dir == git.git_dir
        && record.common_git_dir == git.common_git_dir
        && record.branch_ref == git.branch_ref
        && record.base_revision == git.base_revision
        && record.result_revision == git.result_revision
        && record.advertised_ref == git.advertised_ref
        && record.import_ref == git.import_ref
        && record.object_format == git.object_format;
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "applied Git import differs from the durable journal",
        ))
    }
}

async fn require_import_authority(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteResultImportRecord,
) -> Result<(), CliError> {
    let assignment = load_assignment_in_tx(transaction, &record.assignment_id)
        .await?
        .ok_or_else(|| concurrent("remote result import assignment disappeared"))?;
    let parent = load_execution_in_tx(transaction, &record.execution_id)
        .await?
        .ok_or_else(|| concurrent("remote result import execution disappeared"))?;
    let materials =
        load_import_materials(transaction, &assignment, &parent, &record.request()).await?;
    require_record_materials(record, &assignment, &materials)?;
    if TaskBoardWorkflowExecutionCas::from(&parent).record_sha256 == record.parent_record_sha256
        && parent
            .ownership
            .resources
            .get(TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE)
            == Some(&record.import_sha256)
    {
        Ok(())
    } else {
        Err(concurrent("remote result import parent authority changed"))
    }
}
