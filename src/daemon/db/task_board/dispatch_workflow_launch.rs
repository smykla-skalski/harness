use super::dispatch_preparations::TaskBoardDispatchPreparation;
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    AgentMode, PlanApprovalGate, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardItem,
    TaskBoardReadOnlyRunContext, TaskBoardReadOnlyWorkflowLaunch, TaskBoardWorkflowKind,
    TaskBoardWorkflowSnapshot, TaskBoardWriteWorkflowLaunch, approval_gate, bind_plan_approval,
    build_planning_result, validate_plan_approval, validate_task_board_read_only_item_revisions,
    validate_task_board_read_only_run_context,
};

pub(super) fn prepare_workflow_launches_for_publication(
    preparation: &TaskBoardDispatchPreparation,
    item: &TaskBoardItem,
    revision: i64,
    worktree: &str,
    mut read_only: Option<TaskBoardReadOnlyWorkflowLaunch>,
    mut write: Option<Box<TaskBoardWriteWorkflowLaunch>>,
) -> Result<
    (
        Option<TaskBoardReadOnlyWorkflowLaunch>,
        Option<Box<TaskBoardWriteWorkflowLaunch>>,
    ),
    CliError,
> {
    if read_only.is_some() && write.is_some() {
        return Err(db_error("dispatch supplied conflicting workflow launches"));
    }
    match (
        preparation.source_item_revision,
        read_only.as_mut(),
        write.as_mut(),
    ) {
        (Some(source), Some(launch), None) => {
            prepare_read_only(preparation, item, revision, source, worktree, launch)?;
        }
        (Some(source), None, Some(launch)) => {
            prepare_write(item, revision, source, launch)?;
        }
        (Some(_), None, None) => {
            return Err(db_error("workflow dispatch preparation omitted its launch"));
        }
        (None, Some(_), None) | (None, None, Some(_)) => {
            return Err(db_error("non-workflow dispatch supplied a workflow launch"));
        }
        (None, None, None) => {}
        (_, Some(_), Some(_)) => unreachable!("conflicting launches rejected above"),
    }
    Ok((read_only, write))
}

pub(super) fn rebind_write_launch(
    item: &TaskBoardItem,
    launch: &mut TaskBoardWriteWorkflowLaunch,
    execution_id: &str,
    started_item_revision: i64,
) -> Result<(), CliError> {
    let prior_snapshot = write_snapshot(launch, launch.planning_result.item_revision);
    let PlanApprovalGate::Approved {
        approved_by,
        approved_at,
    } = approval_gate(item)
    else {
        return Err(db_error(
            "write workflow plan approval changed before publication",
        ));
    };
    let expected = build_planning_result(
        item.planning.summary.as_deref().unwrap_or_default(),
        acceptance_criteria(item),
        &prior_snapshot,
        execution_id,
    )
    .map_err(|error| db_error(format!("validate write launch plan: {error}")))?;
    let expected_approval = bind_plan_approval(
        &expected,
        &prior_snapshot,
        execution_id,
        &approved_by,
        &approved_at,
    )
    .map_err(|error| db_error(format!("validate write launch approval: {error}")))?;
    if expected != launch.planning_result
        || expected_approval != launch.plan_approval
        || !validate_plan_approval(
            &launch.plan_approval,
            &launch.planning_result,
            &prior_snapshot,
            execution_id,
        )
        .valid
    {
        return Err(db_error(
            "write workflow planning evidence changed before publication",
        ));
    }
    let snapshot = write_snapshot(launch, started_item_revision);
    let planning_result = build_planning_result(
        &launch.planning_result.plan_markdown,
        launch.planning_result.acceptance_criteria.clone(),
        &snapshot,
        execution_id,
    )
    .map_err(|error| db_error(format!("rebind write launch plan: {error}")))?;
    let plan_approval = bind_plan_approval(
        &planning_result,
        &snapshot,
        execution_id,
        &launch.plan_approval.approved_by,
        &launch.plan_approval.approved_at,
    )
    .map_err(|error| db_error(format!("rebind write launch approval: {error}")))?;
    launch.planning_result = planning_result;
    launch.plan_approval = plan_approval;
    Ok(())
}

fn write_snapshot(
    launch: &TaskBoardWriteWorkflowLaunch,
    item_revision: i64,
) -> TaskBoardWorkflowSnapshot {
    TaskBoardWorkflowSnapshot {
        workflow_kind: launch.workflow_kind,
        execution_repository: launch.execution_repository.clone(),
        item_revision,
        configuration_revision: launch.configuration_revision,
        policy_version: launch.policy_version.clone(),
        reviewer: launch.resolved_reviewers.clone(),
        read_only_run_context: None,
        provider_revision: launch.provider_revision.clone(),
    }
}

fn acceptance_criteria(item: &TaskBoardItem) -> Vec<String> {
    (!item.body.trim().is_empty())
        .then(|| item.body.clone())
        .into_iter()
        .collect()
}

fn prepare_read_only(
    preparation: &TaskBoardDispatchPreparation,
    item: &TaskBoardItem,
    revision: i64,
    source: i64,
    worktree: &str,
    launch: &mut TaskBoardReadOnlyWorkflowLaunch,
) -> Result<(), CliError> {
    validate_task_board_read_only_item_revisions(
        launch.source_item_revision,
        launch.prepared_item_revision,
    )
    .map_err(|error| db_error(error.to_string()))?;
    if revision != source
        || launch.source_item_revision != source
        || launch.prepared_item_revision != source
    {
        return Err(db_error(
            "read-only workflow item revision changed before preparation publication",
        ));
    }
    if launch.workflow_kind != item.workflow_kind
        || !matches!(
            item.workflow_kind,
            TaskBoardWorkflowKind::Review | TaskBoardWorkflowKind::PrReview
        )
        || item.agent_mode != AgentMode::Evaluate
    {
        return Err(db_error(
            "read-only workflow identity changed before preparation publication",
        ));
    }
    launch.run_context = TaskBoardReadOnlyRunContext {
        schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
        session_id: preparation.session_id.clone(),
        title: item.title.clone(),
        body: item.body.clone(),
        tags: item.tags.clone(),
        worktree: worktree.to_string(),
    };
    validate_task_board_read_only_run_context(&launch.run_context)
        .map_err(|error| db_error(format!("validate read-only run context: {error}")))
}

fn prepare_write(
    item: &TaskBoardItem,
    revision: i64,
    source: i64,
    launch: &TaskBoardWriteWorkflowLaunch,
) -> Result<(), CliError> {
    validate_task_board_read_only_item_revisions(
        launch.source_item_revision,
        launch.prepared_item_revision,
    )
    .map_err(|error| db_error(error.to_string()))?;
    if revision != source
        || launch.source_item_revision != source
        || launch.prepared_item_revision != source
    {
        return Err(db_error(
            "write workflow item revision changed before preparation publication",
        ));
    }
    if launch.workflow_kind != item.workflow_kind
        || !matches!(
            item.workflow_kind,
            TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
        )
        || item.agent_mode != AgentMode::Headless
    {
        return Err(db_error(
            "write workflow identity changed before preparation publication",
        ));
    }
    Ok(())
}
