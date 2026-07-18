use crate::daemon::db::AsyncDaemonDb;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    AgentMode, DispatchAppliedTask, PlanApprovalGate, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
    TaskBoardItem, TaskBoardPullRequestIdentity, TaskBoardReadOnlyRunContext,
    TaskBoardWorkflowKind, TaskBoardWorkflowSnapshot, TaskBoardWriteWorkflowLaunch, approval_gate,
    bind_plan_approval, build_planning_result, resolve_task_board_pull_request_identity,
    resolve_task_board_reviewers, task_board_read_only_execution_repository,
    validate_task_board_read_only_run_context,
};

pub(super) async fn prepare_write_workflow_launch(
    db: &AsyncDaemonDb,
    item_id: &str,
    session_id: &str,
    task_id: &str,
    execution_id: &str,
    worktree: &str,
    source_item_revision: Option<i64>,
) -> Result<Option<Box<TaskBoardWriteWorkflowLaunch>>, CliError> {
    let item_snapshot = db.task_board_item_snapshot(item_id).await?;
    let item = item_snapshot.item;
    if !is_write_workflow(item.workflow_kind) {
        return Ok(None);
    }
    let source_item_revision = source_item_revision.ok_or_else(|| {
        invalid_transition("write workflow preparation has no frozen item revision")
    })?;
    if item_snapshot.item_revision != source_item_revision {
        return Err(invalid_transition(
            "write workflow item revision changed after dispatch reservation",
        ));
    }
    if item.agent_mode != AgentMode::Headless {
        return Err(invalid_transition(
            "DefaultTask and PrFix workflows require Headless agent mode",
        ));
    }
    let settings = db.task_board_orchestrator_settings_snapshot().await?;
    let configuration_revision = u64::try_from(settings.row_revision)
        .map_err(|_| invalid_transition("orchestrator settings revision is out of range"))?;
    let execution_repository = task_board_read_only_execution_repository(&item)
        .map_err(|error| invalid_transition(error.to_string()))?;
    let resolved_reviewers = resolve_task_board_reviewers(
        &settings.settings.reviewers,
        item.workflow_kind,
        execution_repository.as_deref(),
    )
    .map_err(|error| invalid_transition(error.to_string()))?;
    super::read_only_workflow_launch::ensure_supported_runtimes(&resolved_reviewers)?;
    let (pull_request, base_head_revision) = resolve_write_identity(&item, worktree).await?;
    let (approved_by, approved_at) = approved_plan(&item)?;
    let snapshot = workflow_snapshot(
        &item,
        source_item_revision,
        configuration_revision,
        settings.settings.policy_version,
        resolved_reviewers,
        execution_repository,
        None,
    );
    let result = build_planning_result(
        item.planning.summary.as_deref().unwrap_or_default(),
        acceptance_criteria(&item),
        &snapshot,
        execution_id,
    )
    .map_err(|error| invalid_transition(error.to_string()))?;
    let approval = bind_plan_approval(&result, &snapshot, execution_id, &approved_by, &approved_at)
        .map_err(|error| invalid_transition(error.to_string()))?;
    Ok(Some(Box::new(TaskBoardWriteWorkflowLaunch {
        workflow_kind: item.workflow_kind,
        execution_repository: snapshot.execution_repository,
        configuration_revision,
        policy_version: snapshot.policy_version,
        resolved_reviewers: snapshot.reviewer,
        source_item_revision,
        prepared_item_revision: source_item_revision,
        task_id: task_id.to_string(),
        run_context: TaskBoardReadOnlyRunContext {
            schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
            session_id: session_id.to_string(),
            title: item.title.clone(),
            body: item.body.clone(),
            tags: item.tags.clone(),
            worktree: worktree.to_string(),
        },
        provider_revision: None,
        pull_request,
        base_head_revision,
        planning_result: result,
        plan_approval: approval,
    })))
}

pub(crate) async fn validate_write_workflow_launch(
    db: &AsyncDaemonDb,
    applied: &DispatchAppliedTask,
) -> Result<(), CliError> {
    let Some(launch) = applied.write_workflow.as_ref() else {
        return Ok(());
    };
    validate_task_board_read_only_run_context(&launch.run_context)
        .map_err(|error| invalid_transition(error.to_string()))?;
    if applied.read_only_workflow.is_some() {
        return Err(invalid_transition(
            "dispatch carries conflicting workflow launches",
        ));
    }
    let item_snapshot = db.task_board_item_snapshot(&applied.board_item_id).await?;
    let item = item_snapshot.item;
    let settings = db.task_board_orchestrator_settings_snapshot().await?;
    let configuration_revision = u64::try_from(settings.row_revision)
        .map_err(|_| invalid_transition("orchestrator settings revision is out of range"))?;
    let execution_repository = task_board_read_only_execution_repository(&item)
        .map_err(|error| invalid_transition(error.to_string()))?;
    let reviewers = resolve_task_board_reviewers(
        &settings.settings.reviewers,
        item.workflow_kind,
        execution_repository.as_deref(),
    )
    .map_err(|error| invalid_transition(error.to_string()))?;
    super::read_only_workflow_launch::ensure_supported_runtimes(&reviewers)?;
    let started_item_revision = launch
        .prepared_item_revision
        .checked_add(1)
        .ok_or_else(|| invalid_transition("workflow item revision is out of range"))?;
    let snapshot = workflow_snapshot(
        &item,
        started_item_revision,
        configuration_revision,
        settings.settings.policy_version,
        reviewers,
        execution_repository,
        launch.provider_revision.clone(),
    );
    let execution_id = item
        .workflow
        .execution_id
        .as_deref()
        .ok_or_else(|| invalid_transition("write workflow item has no execution id"))?;
    let (approved_by, approved_at) = approved_plan(&item)?;
    let result = build_planning_result(
        item.planning.summary.as_deref().unwrap_or_default(),
        acceptance_criteria(&item),
        &snapshot,
        execution_id,
    )
    .map_err(|error| invalid_transition(error.to_string()))?;
    let approval = bind_plan_approval(&result, &snapshot, execution_id, &approved_by, &approved_at)
        .map_err(|error| invalid_transition(error.to_string()))?;
    let (pull_request, base_head_revision) =
        resolve_write_identity(&item, worktree(&item)?).await?;
    let stable = item.workflow_kind == launch.workflow_kind
        && item.agent_mode == AgentMode::Headless
        && snapshot.execution_repository == launch.execution_repository
        && configuration_revision == launch.configuration_revision
        && snapshot.policy_version == launch.policy_version
        && snapshot.reviewer == launch.resolved_reviewers
        && item_snapshot.item_revision == launch.prepared_item_revision
        && launch.task_id == applied.work_item_id
        && launch.run_context.session_id == applied.session_id
        && launch.run_context.title == item.title
        && launch.run_context.body == item.body
        && launch.run_context.tags == item.tags
        && item.session_id.as_deref() == Some(launch.run_context.session_id.as_str())
        && item.workflow.worktree.as_deref() == Some(launch.run_context.worktree.as_str())
        && result == launch.planning_result
        && approval == launch.plan_approval
        && pull_request == launch.pull_request
        && base_head_revision == launch.base_head_revision
        && applied.item.workflow.execution_id.as_deref() == Some(execution_id);
    if stable {
        Ok(())
    } else {
        Err(invalid_transition(
            "write workflow launch contract changed before worker start",
        ))
    }
}

async fn resolve_write_identity(
    item: &TaskBoardItem,
    worktree: &str,
) -> Result<(Option<TaskBoardPullRequestIdentity>, String), CliError> {
    let local_head = super::read_only_workflow_launch::resolve_worktree_head(worktree).await?;
    if item.workflow_kind != TaskBoardWorkflowKind::PrFix {
        return Ok((None, local_head));
    }
    let identity = resolve_task_board_pull_request_identity(item)
        .map_err(|error| invalid_transition(error.to_string()))?;
    let remote_head = super::read_only_workflow_launch::resolve_pr_review_head(&identity).await?;
    if remote_head != local_head {
        return Err(invalid_transition(
            "PrFix worktree HEAD does not match its pull request head",
        ));
    }
    Ok((Some(identity), local_head))
}

fn workflow_snapshot(
    item: &TaskBoardItem,
    item_revision: i64,
    configuration_revision: u64,
    policy_version: String,
    reviewer: crate::task_board::TaskBoardResolvedReviewer,
    execution_repository: Option<String>,
    provider_revision: Option<String>,
) -> TaskBoardWorkflowSnapshot {
    TaskBoardWorkflowSnapshot {
        workflow_kind: item.workflow_kind,
        execution_repository,
        item_revision,
        configuration_revision,
        policy_version,
        reviewer,
        read_only_run_context: None,
        provider_revision,
    }
}

fn approved_plan(item: &TaskBoardItem) -> Result<(String, String), CliError> {
    match approval_gate(item) {
        PlanApprovalGate::Approved {
            approved_by,
            approved_at,
        } => Ok((approved_by, approved_at)),
        PlanApprovalGate::Blocked { reason } => Err(invalid_transition(format!(
            "write workflow plan is not approved: {reason:?}"
        ))),
    }
}

fn acceptance_criteria(item: &TaskBoardItem) -> Vec<String> {
    (!item.body.trim().is_empty())
        .then(|| item.body.clone())
        .into_iter()
        .collect()
}

fn worktree(item: &TaskBoardItem) -> Result<&str, CliError> {
    item.workflow
        .worktree
        .as_deref()
        .ok_or_else(|| invalid_transition("write workflow item has no local worktree"))
}

const fn is_write_workflow(kind: TaskBoardWorkflowKind) -> bool {
    matches!(
        kind,
        TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
    )
}

fn invalid_transition(detail: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(detail.into()).into()
}
