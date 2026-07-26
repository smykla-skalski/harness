use sqlx::{Sqlite, Transaction};

use super::super::audit::insert_audit_event_if_absent_in_tx;
use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::automation_cancel_targets::cancel_target_in_tx;
use super::items::bump_change_in_tx;
use super::remote_assignment_stop_fence::{RemoteTargetStopPlan, remote_target_stop_plan_in_tx};
use super::workflow_execution_attempts::{
    attempt_cas_matches, validate_atomic_execution_attempt_update,
};
use super::workflow_executions::{cas_mismatch, load_execution_in_tx, update_execution_in_tx};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::protocol::HarnessMonitorAuditEvent;
use crate::task_board::{
    TaskBoardAutomationCancelTarget, TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptRecord,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
};

pub(crate) struct AuditedRemoteCancelCasOutcome {
    pub(crate) record: Option<TaskBoardWorkflowExecutionRecord>,
    pub(crate) audit_inserted: bool,
}

impl AsyncDaemonDb {
    pub(crate) async fn compare_and_set_task_board_remote_cancel_with_audit(
        &self,
        expected_execution: &TaskBoardWorkflowExecutionCas,
        target: &TaskBoardAutomationCancelTarget,
        updated_execution: &TaskBoardWorkflowExecutionRecord,
        expected_attempt: &TaskBoardExecutionAttemptCas,
        updated_attempt: &TaskBoardExecutionAttemptRecord,
        audit: &HarnessMonitorAuditEvent,
    ) -> Result<AuditedRemoteCancelCasOutcome, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("audited task board remote cancellation")
            .await?;
        // Every staleness verdict still commits rather than drops. Nothing has
        // been written on those paths -- the screen only reads, and the apply
        // refuses ahead of its first write -- so an empty commit leaves the same
        // state as the rollback it replaces. The apply's own writes reach this
        // commit too, which is why settling at one exit keeps the verdict and
        // the transaction from drifting apart.
        let outcome = match screen_audited_remote_cancel_in_tx(
            &mut transaction,
            expected_execution,
            target,
            expected_attempt,
        )
        .await?
        {
            None => stale(),
            Some(screened) => apply_audited_remote_cancel_in_tx(
                &mut transaction,
                expected_execution,
                (updated_execution, updated_attempt),
                &screened,
                audit,
            )
            .await?
            .unwrap_or_else(stale),
        };
        transaction
            .commit()
            .await
            .map_err(|error| commit_error(&error))?;
        Ok(outcome)
    }
}

/// The execution and attempt an audited cancellation proved it still owns.
struct ScreenedRemoteCancel {
    current: TaskBoardWorkflowExecutionRecord,
    attempt_index: usize,
    current_attempt: TaskBoardExecutionAttemptRecord,
}

/// Resolve what the cancellation may write, or `None` when anything it was
/// compared against has moved.
async fn screen_audited_remote_cancel_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected_execution: &TaskBoardWorkflowExecutionCas,
    target: &TaskBoardAutomationCancelTarget,
    expected_attempt: &TaskBoardExecutionAttemptCas,
) -> Result<Option<ScreenedRemoteCancel>, CliError> {
    if !exact_cancel_target_in_tx(transaction, expected_execution, target).await? {
        return Ok(None);
    }
    let Some(current) = load_execution_in_tx(transaction, &expected_execution.execution_id).await?
    else {
        return Ok(None);
    };
    let Some((attempt_index, current_attempt)) =
        matched_cancel_attempt(&current, expected_execution, expected_attempt)
    else {
        return Ok(None);
    };
    Ok(Some(ScreenedRemoteCancel {
        current,
        attempt_index,
        current_attempt,
    }))
}

/// Whether the cancellation still names exactly the target the caller read, and
/// that target has not already been asked to stop.
async fn exact_cancel_target_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected_execution: &TaskBoardWorkflowExecutionCas,
    target: &TaskBoardAutomationCancelTarget,
) -> Result<bool, CliError> {
    let current = cancel_target_in_tx(transaction, &expected_execution.execution_id).await?;
    Ok(current.as_ref() == Some(target) && !target.cancel_pending)
}

/// The attempt the CAS names, only while both the execution and that attempt
/// still carry what the caller compared against.
fn matched_cancel_attempt(
    current: &TaskBoardWorkflowExecutionRecord,
    expected_execution: &TaskBoardWorkflowExecutionCas,
    expected_attempt: &TaskBoardExecutionAttemptCas,
) -> Option<(usize, TaskBoardExecutionAttemptRecord)> {
    if cas_mismatch(expected_execution, current).is_some() {
        return None;
    }
    current
        .attempts
        .iter()
        .enumerate()
        .find(|(_, attempt)| {
            attempt.action_key == expected_attempt.action_key
                && attempt.attempt == expected_attempt.attempt
        })
        .filter(|(_, attempt)| attempt_cas_matches(expected_attempt, attempt))
        .map(|(index, attempt)| (index, attempt.clone()))
}

/// Persist the cancellation the screen cleared, returning `None` when the stop
/// plan turns out to want a fresh request rather than a durable cancel intent.
async fn apply_audited_remote_cancel_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected_execution: &TaskBoardWorkflowExecutionCas,
    updated: (
        &TaskBoardWorkflowExecutionRecord,
        &TaskBoardExecutionAttemptRecord,
    ),
    screened: &ScreenedRemoteCancel,
    audit: &HarnessMonitorAuditEvent,
) -> Result<Option<AuditedRemoteCancelCasOutcome>, CliError> {
    let (updated_execution, updated_attempt) = updated;
    let mut combined = updated_execution.clone();
    *combined
        .attempts
        .get_mut(screened.attempt_index)
        .ok_or_else(|| db_error("audited remote cancel removed its expected attempt"))? =
        updated_attempt.clone();
    validate_atomic_execution_attempt_update(
        &screened.current,
        updated_execution,
        &screened.current_attempt,
        updated_attempt,
        &combined,
    )?;
    let plan = remote_target_stop_plan_in_tx(transaction, &screened.current, &combined).await?;
    let record = match plan {
        RemoteTargetStopPlan::PersistCancelIntent(parent) => {
            update_execution_in_tx(transaction, expected_execution, &parent).await?;
            bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
            parent
        }
        RemoteTargetStopPlan::ReplayedCancelIntent(parent) => parent,
        RemoteTargetStopPlan::ApplyRequested => return Ok(None),
    };
    let audit_inserted = insert_audit_event_if_absent_in_tx(transaction, audit).await?;
    Ok(Some(AuditedRemoteCancelCasOutcome {
        record: Some(record),
        audit_inserted,
    }))
}

fn stale() -> AuditedRemoteCancelCasOutcome {
    AuditedRemoteCancelCasOutcome {
        record: None,
        audit_inserted: false,
    }
}

fn commit_error(error: &sqlx::Error) -> CliError {
    db_error(format!(
        "commit audited task board remote cancellation: {error}"
    ))
}
