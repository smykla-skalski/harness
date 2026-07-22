use std::collections::BTreeMap;

use sqlx::{Sqlite, Transaction, query_scalar};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::workflow_execution_attempts::insert_attempt_in_tx;
use super::workflow_executions::insert_execution_in_tx;
use crate::daemon::db::{CliError, db_error, utc_now};
use crate::task_board::{
    AgentMode, PlanApprovalGate, TaskBoardAttemptState, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionOwnership, TaskBoardExecutionState, TaskBoardReadOnlyWorkflowLaunch,
    TaskBoardWorkflowExecutionArtifacts, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
    TaskBoardWorkflowSnapshot, TaskBoardWriteWorkflowLaunch, advance_task_board_workflow,
    approval_gate, bind_plan_approval, build_planning_result,
    resolve_task_board_pull_request_identity, start_task_board_workflow,
    task_board_read_only_execution_repository, validate_task_board_read_only_item_revisions,
    validate_task_board_read_only_run_context, validate_task_board_workflow_execution,
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
    validate_launch(item, item_revision, launch)?;
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
    transition.execution_state = TaskBoardExecutionState::Preparing;
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
        state: TaskBoardAttemptState::Preparing,
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
            read_only_run_context: Some(launch.run_context.clone()),
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

pub(super) async fn insert_started_write_workflow_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &crate::task_board::TaskBoardItem,
    item_revision: i64,
    intent_id: &str,
    launch: &TaskBoardWriteWorkflowLaunch,
) -> Result<(), CliError> {
    let execution_id = item
        .workflow
        .execution_id
        .as_deref()
        .ok_or_else(|| db_error("write workflow item has no execution id"))?;
    let snapshot = validate_write_launch(item, item_revision, execution_id, launch)?;
    if query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM task_board_workflow_executions WHERE execution_id = ?1)",
    )
    .bind(execution_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("check write workflow execution: {error}")))?
    {
        return Err(db_error(format!(
            "write workflow execution '{execution_id}' already exists"
        )));
    }
    let mut transition = start_task_board_workflow(
        launch.workflow_kind,
        launch.pull_request.as_ref(),
        Some(&launch.base_head_revision),
    )
    .and_then(|state| {
        advance_task_board_workflow(
            &state,
            launch.pull_request.as_ref(),
            Some(&launch.base_head_revision),
        )
    })
    .and_then(|state| {
        advance_task_board_workflow(
            &state,
            launch.pull_request.as_ref(),
            Some(&launch.base_head_revision),
        )
    })
    .map_err(|error| db_error(format!("start write workflow: {error}")))?;
    transition.execution_state = TaskBoardExecutionState::Preparing;
    let now = utc_now();
    let attempt = TaskBoardExecutionAttemptRecord {
        execution_id: execution_id.to_string(),
        action_key: "implementation:1".into(),
        attempt: 1,
        idempotency_key: format!("codex-{intent_id}"),
        state: TaskBoardAttemptState::Preparing,
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
        resolved_reviewers: snapshot.reviewer.clone(),
        snapshot,
        transition,
        artifacts: TaskBoardWorkflowExecutionArtifacts {
            planning_result: Some(launch.planning_result.clone()),
            plan_approval: Some(launch.plan_approval.clone()),
            ..TaskBoardWorkflowExecutionArtifacts::default()
        },
        ownership: TaskBoardExecutionOwnership {
            host_id: None,
            fencing_epoch: 0,
            resources: BTreeMap::from([
                ("admission_owner".into(), workflow_owner(execution_id)),
                ("task_id".into(), launch.task_id.clone()),
            ]),
        },
        available_at: None,
        blocked_reason: None,
        created_at: now.clone(),
        updated_at: now,
        completed_at: None,
        attempts: vec![attempt.clone()],
    };
    validate_task_board_workflow_execution(&record)
        .map_err(|error| db_error(format!("validate dispatched write workflow: {error}")))?;
    record.attempts.clear();
    insert_execution_in_tx(transaction, &record).await?;
    insert_attempt_in_tx(transaction, &attempt).await?;
    bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    Ok(())
}

fn validate_write_launch(
    item: &crate::task_board::TaskBoardItem,
    item_revision: i64,
    execution_id: &str,
    launch: &TaskBoardWriteWorkflowLaunch,
) -> Result<TaskBoardWorkflowSnapshot, CliError> {
    validate_task_board_read_only_run_context(&launch.run_context)
        .map_err(|error| db_error(error.to_string()))?;
    validate_task_board_read_only_item_revisions(
        launch.source_item_revision,
        launch.prepared_item_revision,
    )
    .map_err(|error| db_error(error.to_string()))?;
    let started_revision = launch
        .prepared_item_revision
        .checked_add(1)
        .ok_or_else(|| db_error("workflow item revision is out of range"))?;
    let execution_repository = task_board_read_only_execution_repository(item)
        .map_err(|error| db_error(error.to_string()))?;
    let pull_request = match item.workflow_kind {
        TaskBoardWorkflowKind::PrFix => Some(
            resolve_task_board_pull_request_identity(item)
                .map_err(|error| db_error(error.to_string()))?,
        ),
        TaskBoardWorkflowKind::DefaultTask => None,
        _ => return Err(db_error("dispatch is not a write workflow")),
    };
    let PlanApprovalGate::Approved {
        approved_by,
        approved_at,
    } = approval_gate(item)
    else {
        return Err(db_error(
            "write workflow plan approval changed before durable start",
        ));
    };
    if item.agent_mode != AgentMode::Headless
        || item.workflow_kind != launch.workflow_kind
        || execution_repository != launch.execution_repository
        || pull_request != launch.pull_request
        || item_revision != started_revision
        || item.session_id.as_deref() != Some(launch.run_context.session_id.as_str())
        || item.title != launch.run_context.title
        || item.body != launch.run_context.body
        || item.tags != launch.run_context.tags
        || item.workflow.worktree.as_deref() != Some(launch.run_context.worktree.as_str())
        || item.work_item_id.as_deref() != Some(launch.task_id.as_str())
        || launch.plan_approval.execution_id != execution_id
        || launch.base_head_revision.trim().is_empty()
    {
        return Err(db_error(
            "write workflow launch changed before durable start",
        ));
    }
    let snapshot = TaskBoardWorkflowSnapshot {
        workflow_kind: launch.workflow_kind,
        execution_repository: launch.execution_repository.clone(),
        item_revision,
        configuration_revision: launch.configuration_revision,
        policy_version: launch.policy_version.clone(),
        reviewer: launch.resolved_reviewers.clone(),
        read_only_run_context: Some(launch.run_context.clone()),
        provider_revision: launch.provider_revision.clone(),
    };
    let planning_result = build_planning_result(
        item.planning.summary.as_deref().unwrap_or_default(),
        (!item.body.trim().is_empty()).then(|| item.body.clone()),
        &snapshot,
        execution_id,
    )
    .map_err(|error| db_error(format!("validate durable write plan: {error}")))?;
    let plan_approval = bind_plan_approval(
        &planning_result,
        &snapshot,
        execution_id,
        &approved_by,
        &approved_at,
    )
    .map_err(|error| db_error(format!("validate durable write approval: {error}")))?;
    if planning_result != launch.planning_result || plan_approval != launch.plan_approval {
        return Err(db_error(
            "write workflow planning evidence changed before durable start",
        ));
    }
    Ok(snapshot)
}

fn validate_launch(
    item: &crate::task_board::TaskBoardItem,
    item_revision: i64,
    launch: &TaskBoardReadOnlyWorkflowLaunch,
) -> Result<(), CliError> {
    let execution_repository = task_board_read_only_execution_repository(item)
        .map_err(|error| db_error(error.to_string()))?;
    validate_task_board_read_only_run_context(&launch.run_context)
        .map_err(|error| db_error(error.to_string()))?;
    validate_task_board_read_only_item_revisions(
        launch.source_item_revision,
        launch.prepared_item_revision,
    )
    .map_err(|error| db_error(error.to_string()))?;
    let started_item_revision = launch
        .prepared_item_revision
        .checked_add(1)
        .ok_or_else(|| db_error("workflow item revision is out of range"))?;
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
        || item.session_id.as_deref() != Some(launch.run_context.session_id.as_str())
        || item.title != launch.run_context.title
        || item.body != launch.run_context.body
        || item.tags != launch.run_context.tags
        || item.workflow.worktree.as_deref() != Some(launch.run_context.worktree.as_str())
        || item_revision != started_item_revision
        || launch.exact_head_revision.trim().is_empty()
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
