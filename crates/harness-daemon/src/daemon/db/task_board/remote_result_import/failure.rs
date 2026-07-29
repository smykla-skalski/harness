use sqlx::query;

use super::super::remote_assignment_io_authority::{active_target_matches, monotonic_time};
use super::super::remote_assignment_model::{
    canonical_time, concurrent, load_assignment_in_tx, nonblank, to_i64,
};
use super::super::workflow_execution_attempts::update_attempt_in_tx;
use super::super::workflow_executions::{load_execution_in_tx, update_execution_in_tx};
use super::super::workflow_terminal::project_terminal_execution_in_tx;
use super::super::{ORCHESTRATOR_CHANGE_SCOPE, items::bump_change_in_tx};
use super::model::{TaskBoardRemoteResultImportRecord, TaskBoardRemoteResultImportState};
use super::storage::require_import;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::{
    TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE, TaskBoardAttemptState,
    TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptRecord, TaskBoardExecutionState,
    TaskBoardFailureClass, TaskBoardTerminalOutcome, TaskBoardTerminalOutcomeKind,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
    validate_task_board_attempt_update, validate_task_board_workflow_execution,
};

const BLOCKED_REASON: &str = "remote_result_import_manual_required";

pub(super) async fn mark_manual_required(
    db: &AsyncDaemonDb,
    assignment_id: &str,
    fencing_epoch: u64,
    import_sha256: &str,
    detail: &str,
    failed_at: &str,
) -> Result<TaskBoardRemoteResultImportRecord, CliError> {
    let detail = bounded_detail(detail)?;
    canonical_time(failed_at, "remote result import failure time")?;
    let mut transaction = db
        .begin_immediate_transaction("task board remote result import manual recovery")
        .await?;
    let record = require_import(
        &mut transaction,
        assignment_id,
        fencing_epoch,
        import_sha256,
    )
    .await?;
    if record.state == TaskBoardRemoteResultImportState::ManualRequired {
        return commit_replayed_manual_state(transaction, record, &detail).await;
    }
    require_recoverable_import_state(&record)?;
    let recovery =
        resolve_manual_recovery_in_tx(&mut transaction, &record, assignment_id, &detail, failed_at)
            .await?;
    persist_manual_recovery_in_tx(&mut transaction, &record, &detail, &recovery).await?;
    commit_manual_recovery(transaction, assignment_id, fencing_epoch, import_sha256).await
}

/// The import already requires manual recovery. Its durable projection must
/// match this detail exactly, and then the transaction commits unchanged.
async fn commit_replayed_manual_state(
    mut transaction: sqlx::Transaction<'_, sqlx::Sqlite>,
    record: TaskBoardRemoteResultImportRecord,
    detail: &str,
) -> Result<TaskBoardRemoteResultImportRecord, CliError> {
    require_manual_replay(&mut transaction, &record, detail).await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit replayed manual result import: {error}")))?;
    Ok(record)
}

fn require_recoverable_import_state(
    record: &TaskBoardRemoteResultImportRecord,
) -> Result<(), CliError> {
    if matches!(
        record.state,
        TaskBoardRemoteResultImportState::Prepared | TaskBoardRemoteResultImportState::Applied
    ) {
        Ok(())
    } else {
        Err(concurrent(
            "remote result import cannot require manual recovery after adoption",
        ))
    }
}

/// The exact generation a manual recovery writes against: the parent as it
/// stands, the stopped parent it becomes, the combined record both the workflow
/// validation and the terminal projection read, and the attempt pair.
struct ManualRecovery {
    parent: TaskBoardWorkflowExecutionRecord,
    stopped_parent: TaskBoardWorkflowExecutionRecord,
    combined: TaskBoardWorkflowExecutionRecord,
    current_attempt: TaskBoardExecutionAttemptRecord,
    failed_attempt: TaskBoardExecutionAttemptRecord,
}

async fn resolve_manual_recovery_in_tx(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    record: &TaskBoardRemoteResultImportRecord,
    assignment_id: &str,
    detail: &str,
    failed_at: &str,
) -> Result<ManualRecovery, CliError> {
    let assignment = load_assignment_in_tx(transaction, assignment_id)
        .await?
        .ok_or_else(|| concurrent("manual result import assignment disappeared"))?;
    let parent = load_execution_in_tx(transaction, &record.execution_id)
        .await?
        .ok_or_else(|| concurrent("manual result import execution disappeared"))?;
    let (attempt_index, current_attempt) = require_active_import(record, &assignment, &parent)?;
    let failed_attempt = failed_attempt(&current_attempt, detail, failed_at)?;
    let stopped_parent = manual_required_parent(&parent, detail, failed_at)?;
    let mut combined = stopped_parent.clone();
    combined.attempts[attempt_index] = failed_attempt.clone();
    validate_task_board_workflow_execution(&combined)
        .map_err(|error| db_error(format!("validate manual result import workflow: {error}")))?;
    Ok(ManualRecovery {
        parent,
        stopped_parent,
        combined,
        current_attempt,
        failed_attempt,
    })
}

/// The parent as a manual recovery leaves it: human-required, unschedulable, its
/// import authority surrendered, and carrying the terminal outcome.
fn manual_required_parent(
    parent: &TaskBoardWorkflowExecutionRecord,
    detail: &str,
    failed_at: &str,
) -> Result<TaskBoardWorkflowExecutionRecord, CliError> {
    let mut stopped = parent.clone();
    stopped.transition.execution_state = TaskBoardExecutionState::HumanRequired;
    stopped.available_at = None;
    stopped.blocked_reason = Some(BLOCKED_REASON.into());
    stopped.updated_at = monotonic_time(&parent.updated_at, failed_at)?;
    stopped
        .ownership
        .resources
        .remove(TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE);
    stopped.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
        kind: TaskBoardTerminalOutcomeKind::HumanRequired,
        summary: format!("remote result import requires manual recovery: {detail}"),
        recorded_at: failed_at.into(),
    });
    Ok(stopped)
}

async fn persist_manual_recovery_in_tx(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    record: &TaskBoardRemoteResultImportRecord,
    detail: &str,
    recovery: &ManualRecovery,
) -> Result<(), CliError> {
    persist_manual_state(transaction, record, detail).await?;
    update_execution_in_tx(
        transaction,
        &TaskBoardWorkflowExecutionCas::from(&recovery.parent),
        &recovery.stopped_parent,
    )
    .await?;
    update_attempt_in_tx(
        transaction,
        &TaskBoardExecutionAttemptCas::from(&recovery.current_attempt),
        &recovery.failed_attempt,
    )
    .await?;
    bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    project_terminal_execution_in_tx(transaction, &recovery.combined).await?;
    Ok(())
}

async fn commit_manual_recovery(
    mut transaction: sqlx::Transaction<'_, sqlx::Sqlite>,
    assignment_id: &str,
    fencing_epoch: u64,
    import_sha256: &str,
) -> Result<TaskBoardRemoteResultImportRecord, CliError> {
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
        .map_err(|error| db_error(format!("commit manual result import: {error}")))?;
    Ok(updated)
}

fn require_active_import(
    record: &TaskBoardRemoteResultImportRecord,
    assignment: &super::super::remote_assignment_model::TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
) -> Result<(usize, TaskBoardExecutionAttemptRecord), CliError> {
    let exact_generation = assignment.fencing_epoch == record.fencing_epoch
        && assignment.execution_id == record.execution_id
        && active_target_matches(parent, assignment)
        && TaskBoardWorkflowExecutionCas::from(parent).record_sha256 == record.parent_record_sha256
        && parent
            .ownership
            .resources
            .get(TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE)
            == Some(&record.import_sha256);
    let attempt = parent.attempts.iter().enumerate().find(|(_, attempt)| {
        attempt.action_key == record.action_key
            && attempt.attempt == record.attempt
            && attempt.idempotency_key == record.idempotency_key
            && matches!(
                attempt.state,
                TaskBoardAttemptState::Starting | TaskBoardAttemptState::Running
            )
    });
    if exact_generation {
        attempt
            .map(|(index, attempt)| (index, attempt.clone()))
            .ok_or_else(|| concurrent("manual result import active attempt disappeared"))
    } else {
        Err(concurrent(
            "manual result import lost its exact generation authority",
        ))
    }
}

fn failed_attempt(
    current: &TaskBoardExecutionAttemptRecord,
    detail: &str,
    failed_at: &str,
) -> Result<TaskBoardExecutionAttemptRecord, CliError> {
    let mut failed = current.clone();
    failed.state = TaskBoardAttemptState::Failed;
    failed.failure_class = Some(TaskBoardFailureClass::Permanent);
    failed.available_at = None;
    failed.error = Some(format!("remote result import is unsafe: {detail}"));
    failed.artifact = None;
    failed.updated_at = monotonic_time(&current.updated_at, failed_at)?;
    failed.completed_at = Some(failed.updated_at.clone());
    validate_task_board_attempt_update(current, &failed)
        .map_err(|error| db_error(format!("validate manual result import attempt: {error}")))?;
    Ok(failed)
}

async fn persist_manual_state(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    record: &TaskBoardRemoteResultImportRecord,
    detail: &str,
) -> Result<(), CliError> {
    let rows = query(
        "UPDATE task_board_remote_result_imports
         SET state = 'manual_required', adopted_at = NULL, last_error = ?1
         WHERE assignment_id = ?2 AND fencing_epoch = ?3
           AND import_sha256 = ?4 AND state = ?5",
    )
    .bind(detail)
    .bind(&record.assignment_id)
    .bind(to_i64(record.fencing_epoch, "manual result import epoch")?)
    .bind(&record.import_sha256)
    .bind(record.state.as_str())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("persist manual result import: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent("manual result import journal changed"))
    }
}

async fn require_manual_replay(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    record: &TaskBoardRemoteResultImportRecord,
    detail: &str,
) -> Result<(), CliError> {
    let parent = load_execution_in_tx(transaction, &record.execution_id)
        .await?
        .ok_or_else(|| concurrent("manual result import execution disappeared"))?;
    let exact = record.last_error.as_deref() == Some(detail)
        && parent.transition.execution_state == TaskBoardExecutionState::HumanRequired
        && parent.blocked_reason.as_deref() == Some(BLOCKED_REASON)
        && !parent
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE)
        && parent.attempts.iter().any(|attempt| {
            attempt.action_key == record.action_key
                && attempt.attempt == record.attempt
                && attempt.idempotency_key == record.idempotency_key
                && attempt.state == TaskBoardAttemptState::Failed
                && attempt.failure_class == Some(TaskBoardFailureClass::Permanent)
        });
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "manual result import replay differs from durable projection",
        ))
    }
}

fn bounded_detail(detail: &str) -> Result<String, CliError> {
    nonblank(detail, "remote result import failure detail")?;
    let detail = detail.trim();
    let mut bounded = String::with_capacity(detail.len().min(4096));
    for character in detail.chars() {
        if bounded.len() + character.len_utf8() > 4096 {
            break;
        }
        bounded.push(character);
    }
    Ok(bounded)
}
