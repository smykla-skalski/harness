use crate::daemon::db::{AsyncDaemonDb, CliError, CliErrorKind, db_error};
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionPhase, TaskBoardExecutionState, TaskBoardOrchestratorSettings,
    TaskBoardWorkflowCasMismatch, TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
    TaskBoardWorkflowKind, validate_task_board_attempt_update,
    validate_task_board_execution_update, validate_task_board_workflow_execution,
};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::workflow_execution_attempts::{
    attempt_cas_matches, attempt_identity_matches, update_attempt_in_tx, validate_attempt_phase,
};
use super::workflow_execution_revisions::live_execution_revision_mismatch_in_tx;
use super::workflow_executions::{cas_mismatch, load_execution_in_tx, update_execution_in_tx};

enum SideEffectClaimDisposition {
    Claim,
    AlreadyClaimed,
}

impl AsyncDaemonDb {
    pub(crate) async fn claim_task_board_workflow_side_effect(
        &self,
        expected_execution: &TaskBoardWorkflowExecutionCas,
        expected_attempt: &TaskBoardExecutionAttemptCas,
        claimed_attempt: &TaskBoardExecutionAttemptRecord,
        now: &str,
    ) -> Result<Option<TaskBoardExecutionAttemptRecord>, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board workflow side-effect claim")
            .await?;
        let Some(parent) =
            load_execution_in_tx(&mut transaction, &expected_execution.execution_id).await?
        else {
            return Err(CliErrorKind::concurrent_modification(
                "workflow execution disappeared before side-effect claim",
            )
            .into());
        };
        let Some((index, current)) = parent
            .attempts
            .iter()
            .enumerate()
            .find(|(_, attempt)| {
                attempt.action_key == expected_attempt.action_key
                    && attempt.attempt == expected_attempt.attempt
            })
            .map(|(index, attempt)| (index, attempt.clone()))
        else {
            return Err(CliErrorKind::concurrent_modification(
                "workflow attempt disappeared before side-effect claim",
            )
            .into());
        };
        if matches!(
            claim_disposition(
                &parent,
                &current,
                expected_execution,
                expected_attempt,
                claimed_attempt,
            )?,
            SideEffectClaimDisposition::AlreadyClaimed
        ) {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit lost workflow side-effect race: {error}"))
            })?;
            return Ok(None);
        }
        validate_task_board_attempt_update(&current, claimed_attempt)
            .map_err(|error| db_error(format!("validate side-effect attempt claim: {error}")))?;
        validate_attempt_phase(&parent, claimed_attempt)?;
        ensure_live_revisions(&mut transaction, &parent).await?;
        let mut parent_state = parent.clone();
        parent_state.transition.execution_state = TaskBoardExecutionState::Starting;
        parent_state.available_at = None;
        parent_state.blocked_reason = None;
        parent_state.updated_at = now.to_string();
        validate_task_board_execution_update(&parent, &parent_state)
            .map_err(|error| db_error(format!("validate side-effect parent claim: {error}")))?;
        let mut claimed_record = parent_state.clone();
        claimed_record.attempts[index] = claimed_attempt.clone();
        validate_task_board_workflow_execution(&claimed_record)
            .map_err(|error| db_error(format!("validate claimed workflow execution: {error}")))?;
        update_execution_in_tx(&mut transaction, expected_execution, &parent_state).await?;
        update_attempt_in_tx(&mut transaction, expected_attempt, claimed_attempt).await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit task board workflow side-effect claim: {error}"
            ))
        })?;
        Ok(Some(claimed_attempt.clone()))
    }
}

fn claim_disposition(
    parent: &TaskBoardWorkflowExecutionRecord,
    current: &TaskBoardExecutionAttemptRecord,
    expected_execution: &TaskBoardWorkflowExecutionCas,
    expected_attempt: &TaskBoardExecutionAttemptCas,
    claimed_attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<SideEffectClaimDisposition, CliError> {
    if matches!(
        parent.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
            | TaskBoardExecutionState::Completed
            | TaskBoardExecutionState::Failed
            | TaskBoardExecutionState::Cancelled
    ) {
        return Err(CliErrorKind::concurrent_modification(
            "workflow execution stopped before side-effect claim",
        )
        .into());
    }
    if attempt_identity_matches(expected_attempt, current)
        && matches!(
            current.state,
            TaskBoardAttemptState::Running
                | TaskBoardAttemptState::RetryWait
                | TaskBoardAttemptState::Completed
                | TaskBoardAttemptState::Failed
                | TaskBoardAttemptState::Cancelled
                | TaskBoardAttemptState::Unknown
        )
    {
        return Ok(SideEffectClaimDisposition::AlreadyClaimed);
    }
    if cas_mismatch(expected_execution, parent).is_some()
        || !attempt_cas_matches(expected_attempt, current)
    {
        return Err(CliErrorKind::concurrent_modification(
            "workflow execution changed before side-effect claim",
        )
        .into());
    }
    if current.state != TaskBoardAttemptState::Starting
        || claimed_attempt.state != TaskBoardAttemptState::Running
        || !matches!(
            parent.transition.phase,
            Some(
                TaskBoardExecutionPhase::Implementation
                    | TaskBoardExecutionPhase::Review
                    | TaskBoardExecutionPhase::Evaluate
                    | TaskBoardExecutionPhase::Publish
            )
        )
    {
        return Err(db_error(
            "workflow side-effect claim requires a Starting external attempt",
        ));
    }
    Ok(SideEffectClaimDisposition::Claim)
}

async fn ensure_live_revisions(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    parent: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), CliError> {
    if matches!(
        parent.snapshot.workflow_kind,
        TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
    ) {
        let settings_json = sqlx::query_scalar::<_, String>(
            "SELECT settings_json FROM task_board_orchestrator_settings WHERE singleton = 1",
        )
        .fetch_one(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load workflow policy version: {error}")))?;
        let settings = serde_json::from_str::<TaskBoardOrchestratorSettings>(&settings_json)
            .map_err(|error| db_error(format!("decode workflow policy version: {error}")))?;
        if settings.policy_version != parent.snapshot.policy_version {
            return Err(CliErrorKind::concurrent_modification(
                "workflow policy version changed before side-effect claim",
            )
            .into());
        }
    }
    let Some(mismatch) = live_execution_revision_mismatch_in_tx(transaction, parent).await? else {
        return Ok(());
    };
    let reason = match mismatch {
        TaskBoardWorkflowCasMismatch::ItemRevision => {
            "workflow item revision changed before side-effect claim"
        }
        TaskBoardWorkflowCasMismatch::ConfigurationRevision => {
            "workflow configuration revision changed before side-effect claim"
        }
        _ => "workflow revision changed before side-effect claim",
    };
    Err(CliErrorKind::concurrent_modification(reason).into())
}
