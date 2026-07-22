use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_io_authority::has_remote_io_authority;
use super::remote_assignment_stop_fence::{
    RemoteTargetStopPlan, remote_stop_requires_cancellation, remote_target_stop_plan_in_tx,
};
use super::workflow_execution_attempts::load_execution_attempts_in_tx;
use super::workflow_execution_revisions::live_execution_revision_mismatch_in_tx;
use super::workflow_execution_rows::{WorkflowExecutionRow, execution_json, label, phase_label};
use crate::daemon::db::{AsyncDaemonDb, CliError, CliErrorKind, db_error};
use crate::task_board::{
    TASK_BOARD_REMOTE_CANCEL_INTENT_RESOURCE, TaskBoardAttemptState, TaskBoardExecutionPhase,
    TaskBoardExecutionState, TaskBoardWorkflowCasMismatch, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionCasOutcome, TaskBoardWorkflowExecutionCreateOutcome,
    TaskBoardWorkflowExecutionRecord, advance_task_board_workflow,
    restart_task_board_workflow_revision, validate_task_board_execution_update,
    validate_task_board_read_only_run_context, validate_task_board_workflow_execution,
};

const SELECT_EXECUTION: &str = "SELECT * FROM task_board_workflow_executions
    WHERE execution_id = ?1";
const SELECT_ACTIVE_EXECUTIONS: &str = "SELECT * FROM task_board_workflow_executions
    WHERE item_id = ?1
      AND state IN ('pending', 'preparing', 'starting', 'running', 'retry_wait',
                    'awaiting_approval', 'draining')
    ORDER BY created_at DESC, execution_id DESC LIMIT 2";

impl AsyncDaemonDb {
    pub(crate) async fn create_or_load_task_board_workflow_execution(
        &self,
        proposed: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardWorkflowExecutionCreateOutcome, CliError> {
        validate_task_board_workflow_execution(proposed)
            .map_err(|error| db_error(format!("validate workflow execution create: {error}")))?;
        let run_context = proposed
            .snapshot
            .read_only_run_context
            .as_ref()
            .ok_or_else(|| db_error("new read-only workflow execution has no immutable context"))?;
        validate_task_board_read_only_run_context(run_context)
            .map_err(|error| db_error(format!("validate workflow run context: {error}")))?;
        if !proposed.attempts.is_empty() {
            return Err(db_error("new workflow execution cannot contain attempts"));
        }
        let mut transaction = self
            .begin_immediate_transaction("task board workflow execution create")
            .await?;
        if let Some(execution) =
            load_active_execution_in_tx(&mut transaction, &proposed.item_id).await?
        {
            validate_active_execution_adoption(&execution, proposed)?;
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit workflow execution create no-op: {error}"))
            })?;
            return Ok(TaskBoardWorkflowExecutionCreateOutcome {
                execution,
                created: false,
            });
        }
        validate_current_create_revisions(&mut transaction, proposed).await?;
        insert_execution_in_tx(&mut transaction, proposed).await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit task board workflow execution create: {error}"
            ))
        })?;
        Ok(TaskBoardWorkflowExecutionCreateOutcome {
            execution: proposed.clone(),
            created: true,
        })
    }

    pub(crate) async fn task_board_workflow_execution(
        &self,
        execution_id: &str,
    ) -> Result<Option<TaskBoardWorkflowExecutionRecord>, CliError> {
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin workflow execution load: {error}")))?;
        let execution = load_execution_in_tx(&mut transaction, execution_id).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit workflow execution load: {error}")))?;
        Ok(execution)
    }

    pub(crate) async fn active_task_board_workflow_execution(
        &self,
        item_id: &str,
    ) -> Result<Option<TaskBoardWorkflowExecutionRecord>, CliError> {
        let mut transaction =
            self.pool().begin().await.map_err(|error| {
                db_error(format!("begin active workflow execution load: {error}"))
            })?;
        let execution = load_active_execution_in_tx(&mut transaction, item_id).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit active workflow execution load: {error}")))?;
        Ok(execution)
    }

    pub(crate) async fn compare_and_set_task_board_workflow_execution(
        &self,
        expected: &TaskBoardWorkflowExecutionCas,
        updated: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardWorkflowExecutionCasOutcome, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board workflow execution CAS")
            .await?;
        let Some(current) = load_execution_in_tx(&mut transaction, &expected.execution_id).await?
        else {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit missing workflow execution CAS: {error}"))
            })?;
            return Ok(TaskBoardWorkflowExecutionCasOutcome::Stale {
                mismatch: TaskBoardWorkflowCasMismatch::ExecutionId,
                current: None,
            });
        };
        ensure_terminal_transition_has_no_active_side_effect(&current, updated)?;
        if let Some(mismatch) = cas_mismatch(expected, &current) {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit stale workflow execution CAS: {error}"))
            })?;
            return Ok(TaskBoardWorkflowExecutionCasOutcome::Stale {
                mismatch,
                current: Some(current),
            });
        }
        if current.transition.phase != updated.transition.phase
            && let Some(mismatch) =
                live_execution_revision_mismatch_in_tx(&mut transaction, &current).await?
        {
            transaction
                .commit()
                .await
                .map_err(|error| db_error(format!("commit stale workflow phase CAS: {error}")))?;
            return Ok(TaskBoardWorkflowExecutionCasOutcome::Stale {
                mismatch,
                current: Some(current),
            });
        }
        validate_task_board_execution_update(&current, updated)
            .map_err(|error| db_error(format!("validate workflow execution CAS: {error}")))?;
        validate_phase_change(&current, updated)?;
        if current == *updated {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit unchanged workflow execution CAS: {error}"))
            })?;
            return Ok(TaskBoardWorkflowExecutionCasOutcome::Unchanged(current));
        }
        let persisted =
            match remote_target_stop_plan_in_tx(&mut transaction, &current, updated).await? {
                RemoteTargetStopPlan::ApplyRequested => updated.clone(),
                RemoteTargetStopPlan::PersistCancelIntent(parent) => parent,
                RemoteTargetStopPlan::ReplayedCancelIntent(parent) => {
                    transaction.commit().await.map_err(|error| {
                        db_error(format!("commit replayed remote cancellation CAS: {error}"))
                    })?;
                    return Ok(TaskBoardWorkflowExecutionCasOutcome::Unchanged(parent));
                }
            };
        update_execution_in_tx(&mut transaction, expected, &persisted).await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit task board workflow execution CAS: {error}"))
        })?;
        Ok(TaskBoardWorkflowExecutionCasOutcome::Updated(persisted))
    }

    pub(crate) async fn task_board_configuration_revision(&self) -> Result<u64, CliError> {
        let revision = query_scalar::<_, i64>(
            "SELECT COALESCE((SELECT revision FROM task_board_orchestrator_settings
             WHERE singleton = 1), 0)",
        )
        .fetch_one(self.pool())
        .await
        .map_err(|error| db_error(format!("read task board configuration revision: {error}")))?;
        u64::try_from(revision)
            .map_err(|_| db_error("task board configuration revision is out of range"))
    }
}

pub(super) async fn load_execution_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    execution_id: &str,
) -> Result<Option<TaskBoardWorkflowExecutionRecord>, CliError> {
    let row = query_as::<_, WorkflowExecutionRow>(SELECT_EXECUTION)
        .bind(execution_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load workflow execution '{execution_id}': {error}")))?;
    let Some(row) = row else {
        return Ok(None);
    };
    let attempts = load_execution_attempts_in_tx(transaction, execution_id).await?;
    row.into_record(attempts).map(Some)
}

async fn load_active_execution_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<Option<TaskBoardWorkflowExecutionRecord>, CliError> {
    let mut rows = query_as::<_, WorkflowExecutionRow>(SELECT_ACTIVE_EXECUTIONS)
        .bind(item_id)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load active workflow for '{item_id}': {error}")))?;
    if rows.len() > 1 {
        return Err(db_error(format!(
            "item '{item_id}' has multiple durable active workflow executions"
        )));
    }
    let Some(row) = rows.pop() else {
        return Ok(None);
    };
    let execution_id = row.execution_id.clone();
    let attempts = load_execution_attempts_in_tx(transaction, &execution_id).await?;
    row.into_record(attempts).map(Some)
}

fn validate_active_execution_adoption(
    current: &TaskBoardWorkflowExecutionRecord,
    proposed: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), CliError> {
    let same_identity =
        current.execution_id == proposed.execution_id && current.item_id == proposed.item_id;
    let same_frozen_contract = current.snapshot == proposed.snapshot
        && current.resolved_reviewers == proposed.resolved_reviewers
        && current.transition.workflow_kind == proposed.transition.workflow_kind
        && current.transition.pull_request == proposed.transition.pull_request
        && current.transition.exact_head_revision == proposed.transition.exact_head_revision
        && current.ownership == proposed.ownership
        && current.created_at == proposed.created_at;
    if same_identity && same_frozen_contract {
        Ok(())
    } else {
        Err(db_error(format!(
            "active workflow execution '{}' conflicts with proposed execution '{}' immutable contract",
            current.execution_id, proposed.execution_id
        )))
    }
}

async fn validate_current_create_revisions(
    transaction: &mut Transaction<'_, Sqlite>,
    proposed: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), CliError> {
    let item_revision = query_scalar::<_, i64>(
        "SELECT revision FROM task_board_items WHERE item_id = ?1 AND deleted_at IS NULL",
    )
    .bind(&proposed.item_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("read workflow item revision: {error}")))?
    .ok_or_else(|| db_error(format!("task-board item '{}' not found", proposed.item_id)))?;
    let configuration_revision = query_scalar::<_, i64>(
        "SELECT COALESCE((SELECT revision FROM task_board_orchestrator_settings
         WHERE singleton = 1), 0)",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("read workflow configuration revision: {error}")))?;
    let expected_configuration = i64::try_from(proposed.snapshot.configuration_revision)
        .map_err(|_| db_error("workflow configuration revision is out of range"))?;
    if item_revision != proposed.snapshot.item_revision
        || configuration_revision != expected_configuration
    {
        return Err(db_error(
            "workflow execution snapshot revisions are stale at creation",
        ));
    }
    Ok(())
}

pub(super) async fn insert_execution_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), CliError> {
    let (snapshot, reviewers, artifacts, ownership) = execution_json(record)?;
    query(
        "INSERT INTO task_board_workflow_executions (
         execution_id, item_id, workflow_kind, phase, state, item_revision,
         configuration_revision, provider_revision, snapshot_json,
         resolved_reviewer_json, host_id, fencing_epoch, available_at, blocked_reason,
         diagnostics_json, resource_ownership_json, created_at, updated_at, completed_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                   ?14, ?15, ?16, ?17, ?18, ?19)",
    )
    .bind(&record.execution_id)
    .bind(&record.item_id)
    .bind(label(record.snapshot.workflow_kind, "workflow kind")?)
    .bind(phase_label(record.transition.phase)?)
    .bind(label(record.transition.execution_state, "execution state")?)
    .bind(record.snapshot.item_revision)
    .bind(
        i64::try_from(record.snapshot.configuration_revision)
            .map_err(|_| db_error("workflow configuration revision is out of range"))?,
    )
    .bind(&record.snapshot.provider_revision)
    .bind(snapshot)
    .bind(reviewers)
    .bind(&record.ownership.host_id)
    .bind(
        i64::try_from(record.ownership.fencing_epoch)
            .map_err(|_| db_error("workflow fencing epoch is out of range"))?,
    )
    .bind(&record.available_at)
    .bind(&record.blocked_reason)
    .bind(artifacts)
    .bind(ownership)
    .bind(&record.created_at)
    .bind(&record.updated_at)
    .bind(&record.completed_at)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("insert workflow execution: {error}")))
}

pub(super) async fn update_execution_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &TaskBoardWorkflowExecutionCas,
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), CliError> {
    let (_, _, artifacts, ownership) = execution_json(record)?;
    let rows = query(
        "UPDATE task_board_workflow_executions SET phase = ?1, state = ?2, host_id = ?3,
         fencing_epoch = ?4, available_at = ?5, blocked_reason = ?6, diagnostics_json = ?7,
         resource_ownership_json = ?8, updated_at = ?9, completed_at = ?10
         WHERE execution_id = ?11 AND phase = ?12 AND state = ?13 AND item_revision = ?14
           AND configuration_revision = ?15 AND provider_revision IS ?16",
    )
    .bind(phase_label(record.transition.phase)?)
    .bind(label(record.transition.execution_state, "execution state")?)
    .bind(&record.ownership.host_id)
    .bind(
        i64::try_from(record.ownership.fencing_epoch)
            .map_err(|_| db_error("workflow fencing epoch is out of range"))?,
    )
    .bind(&record.available_at)
    .bind(&record.blocked_reason)
    .bind(artifacts)
    .bind(ownership)
    .bind(&record.updated_at)
    .bind(&record.completed_at)
    .bind(&expected.execution_id)
    .bind(phase_label(expected.phase)?)
    .bind(label(expected.state, "execution state")?)
    .bind(expected.revisions.item_revision)
    .bind(
        i64::try_from(expected.revisions.configuration_revision)
            .map_err(|_| db_error("workflow configuration revision is out of range"))?,
    )
    .bind(&expected.revisions.provider_revision)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("update workflow execution CAS: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(db_error("workflow execution CAS lost atomic update"))
    }
}

pub(super) fn cas_mismatch(
    expected: &TaskBoardWorkflowExecutionCas,
    current: &TaskBoardWorkflowExecutionRecord,
) -> Option<TaskBoardWorkflowCasMismatch> {
    if expected.execution_id != current.execution_id {
        Some(TaskBoardWorkflowCasMismatch::ExecutionId)
    } else if expected.phase != current.transition.phase {
        Some(TaskBoardWorkflowCasMismatch::Phase)
    } else if expected.state != current.transition.execution_state {
        Some(TaskBoardWorkflowCasMismatch::State)
    } else if expected.revisions.item_revision != current.snapshot.item_revision {
        Some(TaskBoardWorkflowCasMismatch::ItemRevision)
    } else if expected.revisions.configuration_revision != current.snapshot.configuration_revision {
        Some(TaskBoardWorkflowCasMismatch::ConfigurationRevision)
    } else if expected.revisions.provider_revision != current.snapshot.provider_revision {
        Some(TaskBoardWorkflowCasMismatch::ProviderRevision)
    } else if expected.record_sha256 != TaskBoardWorkflowExecutionCas::from(current).record_sha256 {
        Some(TaskBoardWorkflowCasMismatch::Record)
    } else {
        None
    }
}

pub(super) fn ensure_terminal_transition_has_no_active_side_effect(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), CliError> {
    let stops = !is_stopped(current.transition.execution_state)
        && is_stopped(updated.transition.execution_state);
    if stops
        && has_active_external_side_effect(current)
        && !remote_stop_requires_cancellation(current, updated)
    {
        return Err(CliErrorKind::concurrent_modification(
            "workflow execution has an admitted external side effect",
        )
        .into());
    }
    Ok(())
}

fn has_active_external_side_effect(execution: &TaskBoardWorkflowExecutionRecord) -> bool {
    has_remote_io_authority(execution)
        || execution
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_CANCEL_INTENT_RESOURCE)
        || execution
            .attempts
            .iter()
            .any(|attempt| match execution.transition.phase {
                Some(
                    TaskBoardExecutionPhase::Implementation
                    | TaskBoardExecutionPhase::Review
                    | TaskBoardExecutionPhase::Evaluate,
                ) => {
                    matches!(attempt.state, TaskBoardAttemptState::Running)
                }
                Some(TaskBoardExecutionPhase::Publish) => {
                    attempt.action_key == "publish"
                        && attempt.state == TaskBoardAttemptState::Running
                }
                _ => false,
            })
}

const fn is_stopped(state: TaskBoardExecutionState) -> bool {
    matches!(
        state,
        TaskBoardExecutionState::HumanRequired
            | TaskBoardExecutionState::Completed
            | TaskBoardExecutionState::Failed
            | TaskBoardExecutionState::Cancelled
    )
}

pub(super) fn validate_phase_change(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), CliError> {
    if current.transition.phase == updated.transition.phase {
        if current.transition.pull_request != updated.transition.pull_request
            || current.transition.exact_head_revision != updated.transition.exact_head_revision
        {
            return Err(db_error(
                "workflow identity or exact head changed without a phase transition",
            ));
        }
        return Ok(());
    }
    let observed_pull_request = updated.transition.pull_request.as_ref();
    let observed_head = updated.transition.exact_head_revision.as_deref();
    let forward =
        advance_task_board_workflow(&current.transition, observed_pull_request, observed_head).ok();
    if forward.as_ref() == Some(&updated.transition) {
        return Ok(());
    }
    let restarted = restart_task_board_workflow_revision(&current.transition).ok();
    let next_cycle = current.artifacts.current_revision_cycle.checked_add(1);
    if restarted.as_ref() == Some(&updated.transition)
        && next_cycle == Some(updated.artifacts.current_revision_cycle)
    {
        return Ok(());
    }
    Err(db_error(
        "workflow execution phase change bypasses transition matrix",
    ))
}
