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
        let current_target =
            cancel_target_in_tx(&mut transaction, &expected_execution.execution_id).await?;
        if current_target.as_ref() != Some(target) || target.cancel_pending {
            transaction
                .commit()
                .await
                .map_err(|error| commit_error(&error))?;
            return Ok(stale());
        }
        let Some(current) =
            load_execution_in_tx(&mut transaction, &expected_execution.execution_id).await?
        else {
            transaction
                .commit()
                .await
                .map_err(|error| commit_error(&error))?;
            return Ok(stale());
        };
        let Some((attempt_index, current_attempt)) = current
            .attempts
            .iter()
            .enumerate()
            .find(|(_, attempt)| {
                attempt.action_key == expected_attempt.action_key
                    && attempt.attempt == expected_attempt.attempt
            })
            .map(|(index, attempt)| (index, attempt.clone()))
        else {
            transaction
                .commit()
                .await
                .map_err(|error| commit_error(&error))?;
            return Ok(stale());
        };
        if cas_mismatch(expected_execution, &current).is_some()
            || !attempt_cas_matches(expected_attempt, &current_attempt)
        {
            transaction
                .commit()
                .await
                .map_err(|error| commit_error(&error))?;
            return Ok(stale());
        }
        let mut combined = updated_execution.clone();
        *combined
            .attempts
            .get_mut(attempt_index)
            .ok_or_else(|| db_error("audited remote cancel removed its expected attempt"))? =
            updated_attempt.clone();
        validate_atomic_execution_attempt_update(
            &current,
            updated_execution,
            &current_attempt,
            updated_attempt,
            &combined,
        )?;
        let plan = remote_target_stop_plan_in_tx(&mut transaction, &current, &combined).await?;
        let record = match plan {
            RemoteTargetStopPlan::PersistCancelIntent(parent) => {
                update_execution_in_tx(&mut transaction, expected_execution, &parent).await?;
                bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
                parent
            }
            RemoteTargetStopPlan::ReplayedCancelIntent(parent) => parent,
            RemoteTargetStopPlan::ApplyRequested => {
                transaction
                    .commit()
                    .await
                    .map_err(|error| commit_error(&error))?;
                return Ok(stale());
            }
        };
        let audit_inserted = insert_audit_event_if_absent_in_tx(&mut transaction, audit).await?;
        transaction
            .commit()
            .await
            .map_err(|error| commit_error(&error))?;
        Ok(AuditedRemoteCancelCasOutcome {
            record: Some(record),
            audit_inserted,
        })
    }
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
