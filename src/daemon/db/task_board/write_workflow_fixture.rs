use crate::daemon::db::{AsyncDaemonDb, ClaimedTaskBoardDispatchPreparation};
use crate::errors::CliError;
use crate::task_board::{
    AgentMode, DispatchAppliedTask, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardItem,
    TaskBoardReadOnlyRunContext, TaskBoardWorkflowKind, TaskBoardWorkflowSnapshot,
    TaskBoardWriteWorkflowLaunch, bind_plan_approval, build_planning_result,
    resolve_task_board_reviewers,
};

const APPROVED_AT: &str = "2026-07-18T10:00:00Z";

pub(crate) fn approved_write_item(mut item: TaskBoardItem) -> TaskBoardItem {
    item.workflow_kind = TaskBoardWorkflowKind::DefaultTask;
    item.agent_mode = AgentMode::Headless;
    item.planning.summary = Some("# Test plan\n\nExercise the dispatch contract.".into());
    item.planning.approved_by = Some("test-approver".into());
    item.planning.approved_at = Some(APPROVED_AT.into());
    item
}

pub(crate) async fn complete_write_preparation(
    db: &AsyncDaemonDb,
    preparation: &ClaimedTaskBoardDispatchPreparation,
    branch: &str,
    worktree: &str,
) -> Result<DispatchAppliedTask, CliError> {
    let launch = write_launch(db, preparation, worktree).await?;
    db.complete_task_board_dispatch_preparation_with_workflow(
        preparation,
        branch,
        worktree,
        None,
        Some(Box::new(launch)),
    )
    .await
}

async fn write_launch(
    db: &AsyncDaemonDb,
    preparation: &ClaimedTaskBoardDispatchPreparation,
    worktree: &str,
) -> Result<TaskBoardWriteWorkflowLaunch, CliError> {
    let item_snapshot = db
        .task_board_item_snapshot(&preparation.preparation.board_item_id)
        .await?;
    let settings = db.task_board_orchestrator_settings_snapshot().await?;
    let configuration_revision =
        u64::try_from(settings.row_revision).expect("fixture settings revision");
    let reviewers = resolve_task_board_reviewers(
        &settings.settings.reviewers,
        TaskBoardWorkflowKind::DefaultTask,
        None,
    )
    .expect("fixture reviewer resolution");
    let snapshot = TaskBoardWorkflowSnapshot {
        workflow_kind: TaskBoardWorkflowKind::DefaultTask,
        execution_repository: None,
        item_revision: item_snapshot.item_revision,
        configuration_revision,
        policy_version: settings.settings.policy_version,
        reviewer: reviewers.clone(),
        read_only_run_context: None,
        provider_revision: None,
    };
    let execution_id = &preparation.preparation.workflow_execution_id;
    let planning_result = build_planning_result(
        item_snapshot
            .item
            .planning
            .summary
            .as_deref()
            .unwrap_or_default(),
        [item_snapshot.item.body.clone()],
        &snapshot,
        execution_id,
    )
    .expect("fixture planning result");
    let plan_approval = bind_plan_approval(
        &planning_result,
        &snapshot,
        execution_id,
        item_snapshot
            .item
            .planning
            .approved_by
            .as_deref()
            .unwrap_or_default(),
        item_snapshot
            .item
            .planning
            .approved_at
            .as_deref()
            .unwrap_or_default(),
    )
    .expect("fixture plan approval");
    Ok(TaskBoardWriteWorkflowLaunch {
        workflow_kind: snapshot.workflow_kind,
        execution_repository: None,
        configuration_revision,
        policy_version: snapshot.policy_version,
        resolved_reviewers: reviewers,
        source_item_revision: item_snapshot.item_revision,
        prepared_item_revision: item_snapshot.item_revision,
        task_id: preparation.preparation.work_item_id.clone(),
        run_context: TaskBoardReadOnlyRunContext {
            schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
            session_id: preparation.preparation.session_id.clone(),
            title: item_snapshot.item.title,
            body: item_snapshot.item.body,
            tags: item_snapshot.item.tags,
            worktree: worktree.into(),
        },
        provider_revision: None,
        pull_request: None,
        base_head_revision: "fixture-base-head".into(),
        planning_result,
        plan_approval,
    })
}
