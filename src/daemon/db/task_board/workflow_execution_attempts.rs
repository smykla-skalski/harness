use sqlx::{Sqlite, Transaction, query, query_as};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::workflow_execution_rows::{ExecutionAttemptRow, attempt_artifact_json, label};
use super::workflow_executions::load_execution_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionAttemptCasOutcome, TaskBoardExecutionAttemptCreateOutcome,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase, TaskBoardExecutionState,
    TaskBoardWorkflowExecutionRecord, validate_task_board_attempt_update,
    validate_task_board_execution_attempt, validate_task_board_workflow_execution,
};

const SELECT_ATTEMPTS: &str = "SELECT * FROM task_board_execution_attempts
    WHERE execution_id = ?1 ORDER BY action_key, attempt";

impl AsyncDaemonDb {
    pub(crate) async fn create_task_board_execution_attempt(
        &self,
        proposed: &TaskBoardExecutionAttemptRecord,
    ) -> Result<TaskBoardExecutionAttemptCreateOutcome, CliError> {
        validate_task_board_execution_attempt(proposed)
            .map_err(|error| db_error(format!("validate execution attempt create: {error}")))?;
        let mut transaction = self
            .begin_immediate_transaction("task board execution attempt create")
            .await?;
        let parent = load_execution_in_tx(&mut transaction, &proposed.execution_id)
            .await?
            .ok_or_else(|| db_error("execution attempt parent does not exist"))?;
        let by_identity = parent.attempts.iter().find(|attempt| {
            attempt.action_key == proposed.action_key && attempt.attempt == proposed.attempt
        });
        let by_key = parent
            .attempts
            .iter()
            .find(|attempt| attempt.idempotency_key == proposed.idempotency_key);
        if let (Some(by_identity), Some(by_key)) = (by_identity, by_key) {
            let same_record = by_identity == proposed
                && by_identity.action_key == by_key.action_key
                && by_identity.attempt == by_key.attempt
                && by_identity.idempotency_key == by_key.idempotency_key;
            if same_record {
                transaction.commit().await.map_err(|error| {
                    db_error(format!("commit execution attempt create no-op: {error}"))
                })?;
                return Ok(TaskBoardExecutionAttemptCreateOutcome {
                    attempt: by_identity.clone(),
                    created: false,
                });
            }
        }
        if by_identity.is_some() || by_key.is_some() {
            return Err(db_error(
                "execution attempt identity or idempotency key conflicts with durable state",
            ));
        }
        if parent.transition.phase.is_none()
            || matches!(
                parent.transition.execution_state,
                TaskBoardExecutionState::HumanRequired
                    | TaskBoardExecutionState::Completed
                    | TaskBoardExecutionState::Failed
                    | TaskBoardExecutionState::Cancelled
            )
        {
            return Err(db_error(
                "workflow execution is not admitted for a new attempt",
            ));
        }
        validate_attempt_phase(&parent, proposed)?;
        validate_attempt_in_execution(&parent, proposed, None)?;
        insert_attempt_in_tx(&mut transaction, proposed).await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit task board execution attempt create: {error}"
            ))
        })?;
        Ok(TaskBoardExecutionAttemptCreateOutcome {
            attempt: proposed.clone(),
            created: true,
        })
    }

    pub(crate) async fn compare_and_set_task_board_execution_attempt(
        &self,
        expected: &TaskBoardExecutionAttemptCas,
        updated: &TaskBoardExecutionAttemptRecord,
    ) -> Result<TaskBoardExecutionAttemptCasOutcome, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board execution attempt CAS")
            .await?;
        let Some(parent) = load_execution_in_tx(&mut transaction, &expected.execution_id).await?
        else {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit missing execution attempt CAS: {error}"))
            })?;
            return Ok(TaskBoardExecutionAttemptCasOutcome::Stale(None));
        };
        let current = parent.attempts.iter().enumerate().find(|(_, attempt)| {
            attempt.action_key == expected.action_key && attempt.attempt == expected.attempt
        });
        let Some((index, current)) = current.map(|(index, attempt)| (index, attempt.clone()))
        else {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit missing execution attempt CAS: {error}"))
            })?;
            return Ok(TaskBoardExecutionAttemptCasOutcome::Stale(None));
        };
        if attempt_identity_matches(expected, &current) && current == *updated {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit unchanged execution attempt CAS: {error}"))
            })?;
            return Ok(TaskBoardExecutionAttemptCasOutcome::Unchanged(current));
        }
        if !attempt_cas_matches(expected, &current) {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit stale execution attempt CAS: {error}"))
            })?;
            return Ok(TaskBoardExecutionAttemptCasOutcome::Stale(Some(current)));
        }
        validate_task_board_attempt_update(&current, updated)
            .map_err(|error| db_error(format!("validate execution attempt CAS: {error}")))?;
        validate_attempt_phase(&parent, updated)?;
        validate_attempt_in_execution(&parent, updated, Some(index))?;
        ensure_external_side_effect_uses_atomic_claim(&parent, &current, updated)?;
        update_attempt_in_tx(&mut transaction, expected, updated).await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit task board execution attempt CAS: {error}"))
        })?;
        Ok(TaskBoardExecutionAttemptCasOutcome::Updated(
            updated.clone(),
        ))
    }
}

pub(super) async fn load_execution_attempts_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    execution_id: &str,
) -> Result<Vec<TaskBoardExecutionAttemptRecord>, CliError> {
    query_as::<_, ExecutionAttemptRow>(SELECT_ATTEMPTS)
        .bind(execution_id)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load workflow execution attempts: {error}")))?
        .into_iter()
        .map(ExecutionAttemptRow::into_record)
        .collect()
}

pub(super) async fn insert_attempt_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardExecutionAttemptRecord,
) -> Result<(), CliError> {
    query(
        "INSERT INTO task_board_execution_attempts (
         execution_id, action_key, attempt, idempotency_key, state, failure_class,
         available_at, error, artifact_json, started_at, updated_at, completed_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
    )
    .bind(&record.execution_id)
    .bind(&record.action_key)
    .bind(i64::from(record.attempt))
    .bind(&record.idempotency_key)
    .bind(label(record.state, "execution attempt state")?)
    .bind(
        record
            .failure_class
            .map(|value| label(value, "execution attempt failure class"))
            .transpose()?,
    )
    .bind(&record.available_at)
    .bind(&record.error)
    .bind(attempt_artifact_json(record.artifact.as_ref())?)
    .bind(&record.started_at)
    .bind(&record.updated_at)
    .bind(&record.completed_at)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("insert execution attempt: {error}")))
}

pub(super) async fn update_attempt_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &TaskBoardExecutionAttemptCas,
    record: &TaskBoardExecutionAttemptRecord,
) -> Result<(), CliError> {
    let rows = query(
        "UPDATE task_board_execution_attempts SET state = ?1, failure_class = ?2,
         available_at = ?3, error = ?4, artifact_json = ?5, updated_at = ?6,
         completed_at = ?7 WHERE execution_id = ?8 AND action_key = ?9 AND attempt = ?10
         AND idempotency_key = ?11 AND state = ?12",
    )
    .bind(label(record.state, "execution attempt state")?)
    .bind(
        record
            .failure_class
            .map(|value| label(value, "execution attempt failure class"))
            .transpose()?,
    )
    .bind(&record.available_at)
    .bind(&record.error)
    .bind(attempt_artifact_json(record.artifact.as_ref())?)
    .bind(&record.updated_at)
    .bind(&record.completed_at)
    .bind(&expected.execution_id)
    .bind(&expected.action_key)
    .bind(i64::from(expected.attempt))
    .bind(&expected.idempotency_key)
    .bind(label(expected.state, "execution attempt state")?)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("update execution attempt CAS: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(db_error("execution attempt CAS lost atomic update"))
    }
}

pub(super) fn attempt_cas_matches(
    expected: &TaskBoardExecutionAttemptCas,
    current: &TaskBoardExecutionAttemptRecord,
) -> bool {
    attempt_identity_matches(expected, current) && expected.state == current.state
}

pub(super) fn attempt_identity_matches(
    expected: &TaskBoardExecutionAttemptCas,
    current: &TaskBoardExecutionAttemptRecord,
) -> bool {
    expected.execution_id == current.execution_id
        && expected.action_key == current.action_key
        && expected.attempt == current.attempt
        && expected.idempotency_key == current.idempotency_key
}

fn validate_attempt_in_execution(
    parent: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    replace_index: Option<usize>,
) -> Result<(), CliError> {
    let mut candidate = parent.clone();
    if let Some(index) = replace_index {
        candidate.attempts[index] = attempt.clone();
    } else {
        candidate.attempts.push(attempt.clone());
    }
    validate_task_board_workflow_execution(&candidate)
        .map_err(|error| db_error(format!("validate attempt in durable execution: {error}")))
}

pub(super) fn validate_attempt_phase(
    parent: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<(), CliError> {
    if attempt.execution_id != parent.execution_id {
        return Err(db_error(
            "workflow attempt does not belong to its execution",
        ));
    }
    let phase = parent
        .transition
        .phase
        .ok_or_else(|| db_error("workflow execution has no active phase"))?;
    let valid_action = match phase {
        TaskBoardExecutionPhase::Implementation => {
            attempt.action_key
                == format!("implementation:{}", parent.artifacts.current_revision_cycle)
        }
        TaskBoardExecutionPhase::Review => attempt.action_key.starts_with("review:"),
        TaskBoardExecutionPhase::Evaluate => {
            attempt.action_key == "evaluate"
                || attempt.action_key
                    == format!("evaluate:{}", parent.artifacts.current_revision_cycle)
        }
        TaskBoardExecutionPhase::Publish => attempt.action_key == "publish",
        TaskBoardExecutionPhase::Cleanup => attempt.action_key == "cleanup",
        TaskBoardExecutionPhase::Planning
        | TaskBoardExecutionPhase::AwaitingApproval
        | TaskBoardExecutionPhase::Terminal => false,
    };
    if !valid_action {
        return Err(db_error(format!(
            "workflow attempt action '{}' does not belong to phase {phase:?}",
            attempt.action_key
        )));
    }
    validate_completed_artifact(phase, attempt)
}

fn ensure_external_side_effect_uses_atomic_claim(
    parent: &TaskBoardWorkflowExecutionRecord,
    current: &TaskBoardExecutionAttemptRecord,
    updated: &TaskBoardExecutionAttemptRecord,
) -> Result<(), CliError> {
    let external_claim = matches!(
        parent.transition.phase,
        Some(
            TaskBoardExecutionPhase::Review
                | TaskBoardExecutionPhase::Implementation
                | TaskBoardExecutionPhase::Evaluate
                | TaskBoardExecutionPhase::Publish
        )
    ) && (parent.transition.phase != Some(TaskBoardExecutionPhase::Publish)
        || current.action_key == "publish")
        && current.state == TaskBoardAttemptState::Starting
        && updated.state == TaskBoardAttemptState::Running;
    if external_claim {
        Err(db_error(
            "workflow external side-effect requires an atomic parent and attempt claim",
        ))
    } else {
        Ok(())
    }
}

fn validate_completed_artifact(
    phase: TaskBoardExecutionPhase,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<(), CliError> {
    if attempt.state != TaskBoardAttemptState::Completed {
        return Ok(());
    }
    let valid = match (phase, attempt.artifact.as_ref()) {
        (
            TaskBoardExecutionPhase::Implementation,
            Some(TaskBoardAttemptResultArtifact::Implementation(_)),
        )
        | (
            TaskBoardExecutionPhase::Evaluate,
            Some(TaskBoardAttemptResultArtifact::Evaluation(_)),
        )
        | (
            TaskBoardExecutionPhase::Publish | TaskBoardExecutionPhase::Cleanup,
            Some(TaskBoardAttemptResultArtifact::Lifecycle(_)),
        ) => true,
        (
            TaskBoardExecutionPhase::Review,
            Some(TaskBoardAttemptResultArtifact::Review(outcome)),
        ) => attempt.action_key == format!("review:{}", outcome.profile_id),
        _ => false,
    };
    if valid {
        Ok(())
    } else {
        Err(db_error(
            "workflow attempt result artifact contradicts its frozen phase",
        ))
    }
}
