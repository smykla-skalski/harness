use std::collections::BTreeMap;

use sqlx::{Sqlite, Transaction, query_scalar};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::workflow_execution_attempts::insert_attempt_in_tx;
use super::workflow_executions::insert_execution_in_tx;
use crate::daemon::db::{CliError, db_error, utc_now};
use crate::task_board::{
    AgentMode, TaskBoardAttemptState, TaskBoardExecutionAttemptRecord, TaskBoardExecutionOwnership,
    TaskBoardExecutionState, TaskBoardReadOnlyWorkflowLaunch, TaskBoardWorkflowExecutionArtifacts,
    TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind, TaskBoardWorkflowSnapshot,
    resolve_task_board_pull_request_identity, start_task_board_workflow,
    task_board_read_only_execution_repository, validate_task_board_workflow_execution,
};

pub(super) async fn insert_started_read_only_workflow_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &crate::task_board::TaskBoardItem,
    item_revision: i64,
    intent_id: &str,
    launch: &TaskBoardReadOnlyWorkflowLaunch,
) -> Result<(), CliError> {
    let execution_id = item
        .workflow
        .execution_id
        .as_deref()
        .ok_or_else(|| db_error("read-only workflow item has no execution id"))?;
    validate_launch(transaction, item, launch).await?;
    if query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM task_board_workflow_executions WHERE execution_id = ?1)",
    )
    .bind(execution_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("check read-only workflow execution: {error}")))?
    {
        return Err(db_error(format!(
            "read-only workflow execution '{execution_id}' already exists"
        )));
    }
    let now = utc_now();
    let mut transition = start_task_board_workflow(
        launch.workflow_kind,
        launch.pull_request.as_ref(),
        Some(&launch.exact_head_revision),
    )
    .map_err(|error| db_error(format!("start read-only workflow: {error}")))?;
    transition.execution_state = TaskBoardExecutionState::Running;
    let profile = launch
        .resolved_reviewers
        .profiles
        .first()
        .ok_or_else(|| db_error("read-only workflow has no reviewer profile"))?;
    let attempt = TaskBoardExecutionAttemptRecord {
        execution_id: execution_id.to_string(),
        action_key: format!("review:{}", profile.id),
        attempt: 1,
        idempotency_key: format!("codex-{intent_id}"),
        state: TaskBoardAttemptState::Running,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: None,
        started_at: now.clone(),
        updated_at: now.clone(),
        completed_at: None,
    };
    let mut record = TaskBoardWorkflowExecutionRecord {
        execution_id: execution_id.to_string(),
        item_id: item.id.clone(),
        snapshot: TaskBoardWorkflowSnapshot {
            workflow_kind: launch.workflow_kind,
            execution_repository: launch.execution_repository.clone(),
            item_revision,
            configuration_revision: launch.configuration_revision,
            policy_version: launch.policy_version.clone(),
            reviewer: launch.resolved_reviewers.clone(),
            provider_revision: launch.provider_revision.clone(),
        },
        resolved_reviewers: launch.resolved_reviewers.clone(),
        transition,
        artifacts: TaskBoardWorkflowExecutionArtifacts::default(),
        ownership: TaskBoardExecutionOwnership {
            host_id: None,
            fencing_epoch: 0,
            resources: BTreeMap::from([("admission_owner".into(), workflow_owner(execution_id))]),
        },
        available_at: None,
        blocked_reason: None,
        created_at: now.clone(),
        updated_at: now,
        completed_at: None,
        attempts: vec![attempt.clone()],
    };
    validate_task_board_workflow_execution(&record)
        .map_err(|error| db_error(format!("validate dispatched read-only workflow: {error}")))?;
    record.attempts.clear();
    insert_execution_in_tx(transaction, &record).await?;
    insert_attempt_in_tx(transaction, &attempt).await?;
    bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    Ok(())
}

async fn validate_launch(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &crate::task_board::TaskBoardItem,
    launch: &TaskBoardReadOnlyWorkflowLaunch,
) -> Result<(), CliError> {
    let settings_revision = query_scalar::<_, i64>(
        "SELECT revision FROM task_board_orchestrator_settings WHERE singleton = 1",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("read workflow settings revision: {error}")))?;
    let settings_revision = u64::try_from(settings_revision)
        .map_err(|_| db_error("workflow settings revision is out of range"))?;
    let execution_repository = task_board_read_only_execution_repository(item)
        .map_err(|error| db_error(error.to_string()))?;
    let pull_request = match item.workflow_kind {
        TaskBoardWorkflowKind::PrReview => Some(
            resolve_task_board_pull_request_identity(item)
                .map_err(|error| db_error(error.to_string()))?,
        ),
        TaskBoardWorkflowKind::Review => None,
        _ => return Err(db_error("dispatch is not a read-only workflow")),
    };
    if item.workflow_kind != launch.workflow_kind
        || item.agent_mode != AgentMode::Evaluate
        || execution_repository != launch.execution_repository
        || pull_request != launch.pull_request
        || launch.exact_head_revision.trim().is_empty()
        || settings_revision != launch.configuration_revision
    {
        return Err(db_error(
            "read-only workflow launch changed before durable start",
        ));
    }
    Ok(())
}

pub(crate) fn workflow_owner(execution_id: &str) -> String {
    format!("workflow-{execution_id}")
}
