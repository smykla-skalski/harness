use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::protocol::{
    SessionDetail, SessionStartRequest, TaskBoardDispatchRequest, TaskBoardDispatchResponse,
    TaskCreateRequest,
};
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
use crate::task_board::{
    DispatchAppliedTask, DispatchExecutionSummary, DispatchPlan, MachineRegistry, SessionIntent,
    TaskBoardItem, TaskBoardStatus, TaskBoardStore, TaskBoardWorkflowStatus,
    build_dispatch_summary_with_policy_root,
};

use super::super::{
    create_task, create_task_async, start_session_direct, start_session_direct_async,
};

/// Build dispatch plans for task-board items.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded.
pub fn dispatch_task_board(
    request: &TaskBoardDispatchRequest,
    db: Option<&DaemonDb>,
    board: &TaskBoardStore,
) -> Result<TaskBoardDispatchResponse, CliError> {
    let items = selected_dispatch_items(board, request)?;
    let plans = build_dispatch_summary_with_policy_root(&items, board.root());
    if request.dry_run {
        return Ok(DispatchExecutionSummary::dry_run(plans));
    }
    let mut applied = Vec::new();
    for plan in plans.iter().filter(|plan| plan.is_ready()) {
        applied.push(apply_dispatch_plan(request, db, board, plan)?);
    }
    Ok(DispatchExecutionSummary { plans, applied })
}

/// Execute ready dispatch plans for task-board items through the async daemon DB.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded, a session/task cannot
/// be created, or linked board items cannot be persisted.
pub async fn dispatch_task_board_async(
    request: &TaskBoardDispatchRequest,
    async_db: &AsyncDaemonDb,
    board: &TaskBoardStore,
) -> Result<TaskBoardDispatchResponse, CliError> {
    let items = selected_dispatch_items(board, request)?;
    let plans = build_dispatch_summary_with_policy_root(&items, board.root());
    if request.dry_run {
        return Ok(DispatchExecutionSummary::dry_run(plans));
    }
    let mut applied = Vec::new();
    for plan in plans.iter().filter(|plan| plan.is_ready()) {
        applied.push(apply_dispatch_plan_async(request, async_db, board, plan).await?);
    }
    Ok(DispatchExecutionSummary { plans, applied })
}

fn selected_dispatch_items(
    board: &TaskBoardStore,
    request: &TaskBoardDispatchRequest,
) -> Result<Vec<TaskBoardItem>, CliError> {
    let items = request.item_id.as_deref().map_or_else(
        || board.list(request.status),
        |item_id| board.get(item_id).map(|item| vec![item]),
    )?;
    Ok(filter_for_local_machine(items, board))
}

fn filter_for_local_machine(
    items: Vec<TaskBoardItem>,
    board: &TaskBoardStore,
) -> Vec<TaskBoardItem> {
    let Ok(machine) = MachineRegistry::new(board.root().to_path_buf()).ensure_local() else {
        return items;
    };
    items
        .into_iter()
        .filter(|item| machine.accepts_any(&item.target_project_types))
        .collect()
}

fn apply_dispatch_plan(
    request: &TaskBoardDispatchRequest,
    db: Option<&DaemonDb>,
    board: &TaskBoardStore,
    plan: &DispatchPlan,
) -> Result<DispatchAppliedTask, CliError> {
    let actor = dispatch_actor(request);
    let session_id = dispatch_session_id(request, db, plan)?;
    let detail = create_task(
        &session_id,
        &TaskCreateRequest {
            actor: actor.to_string(),
            title: plan.task.title.clone(),
            context: plan.task.context.clone(),
            severity: plan.task.severity,
            suggested_fix: plan.task.suggested_fix.clone(),
        },
        db,
    )?;
    let work_item_id = newest_task_id(detail)?;
    let item = link_dispatched_item(board, plan, &session_id, &work_item_id)?;
    Ok(DispatchAppliedTask {
        board_item_id: plan.board_item_id.clone(),
        session_id,
        work_item_id,
        lifecycle: plan.applied_lifecycle(),
        item,
    })
}

async fn apply_dispatch_plan_async(
    request: &TaskBoardDispatchRequest,
    async_db: &AsyncDaemonDb,
    board: &TaskBoardStore,
    plan: &DispatchPlan,
) -> Result<DispatchAppliedTask, CliError> {
    let actor = dispatch_actor(request);
    let session_id = dispatch_session_id_async(request, async_db, plan).await?;
    let detail = create_task_async(
        &session_id,
        &TaskCreateRequest {
            actor: actor.to_string(),
            title: plan.task.title.clone(),
            context: plan.task.context.clone(),
            severity: plan.task.severity,
            suggested_fix: plan.task.suggested_fix.clone(),
        },
        async_db,
    )
    .await?;
    let work_item_id = newest_task_id(detail)?;
    let item = link_dispatched_item(board, plan, &session_id, &work_item_id)?;
    Ok(DispatchAppliedTask {
        board_item_id: plan.board_item_id.clone(),
        session_id,
        work_item_id,
        lifecycle: plan.applied_lifecycle(),
        item,
    })
}

fn dispatch_session_id(
    request: &TaskBoardDispatchRequest,
    db: Option<&DaemonDb>,
    plan: &DispatchPlan,
) -> Result<String, CliError> {
    match &plan.session {
        SessionIntent::Existing { session_id } => Ok(session_id.clone()),
        SessionIntent::Create {
            title,
            context,
            project_id: _,
        } => {
            let state = start_session_direct(
                &SessionStartRequest {
                    title: title.clone(),
                    context: context.clone().unwrap_or_else(|| title.clone()),
                    session_id: None,
                    project_dir: required_dispatch_project_dir(request)?,
                    policy_preset: None,
                    base_ref: None,
                },
                db,
            )?;
            Ok(state.session_id)
        }
    }
}

async fn dispatch_session_id_async(
    request: &TaskBoardDispatchRequest,
    async_db: &AsyncDaemonDb,
    plan: &DispatchPlan,
) -> Result<String, CliError> {
    match &plan.session {
        SessionIntent::Existing { session_id } => Ok(session_id.clone()),
        SessionIntent::Create {
            title,
            context,
            project_id: _,
        } => {
            let state = start_session_direct_async(
                &SessionStartRequest {
                    title: title.clone(),
                    context: context.clone().unwrap_or_else(|| title.clone()),
                    session_id: None,
                    project_dir: required_dispatch_project_dir(request)?,
                    policy_preset: None,
                    base_ref: None,
                },
                async_db,
            )
            .await?;
            Ok(state.session_id)
        }
    }
}

fn dispatch_actor(request: &TaskBoardDispatchRequest) -> &str {
    request.actor.as_deref().unwrap_or(CONTROL_PLANE_ACTOR_ID)
}

fn required_dispatch_project_dir(request: &TaskBoardDispatchRequest) -> Result<String, CliError> {
    request.project_dir.clone().ok_or_else(|| {
        CliErrorKind::workflow_io(
            "task-board dispatch requires project_dir when a session must be created",
        )
        .into()
    })
}

fn newest_task_id(detail: SessionDetail) -> Result<String, CliError> {
    detail
        .tasks
        .into_iter()
        .max_by(|left, right| {
            left.created_at
                .cmp(&right.created_at)
                .then_with(|| left.updated_at.cmp(&right.updated_at))
                .then_with(|| left.task_id.cmp(&right.task_id))
        })
        .map(|task| task.task_id)
        .ok_or_else(|| CliErrorKind::workflow_io("created empty session task list").into())
}

fn link_dispatched_item(
    board: &TaskBoardStore,
    plan: &DispatchPlan,
    session_id: &str,
    work_item_id: &str,
) -> Result<TaskBoardItem, CliError> {
    let current = board.get(&plan.board_item_id)?;
    let mut workflow = current.workflow;
    if workflow.execution_id.is_none() {
        workflow.execution_id = Some(new_workflow_execution_id());
    }
    workflow.status = TaskBoardWorkflowStatus::Running;
    workflow.current_step_id = Some("dispatch".to_string());
    workflow.attempts = workflow.attempts.saturating_add(1);
    workflow.push_policy_trace_id(new_policy_trace_id());
    board.update(
        &plan.board_item_id,
        TaskBoardItemPatch {
            status: Some(TaskBoardStatus::InProgress),
            workflow: Some(workflow),
            session_id: OptionalFieldPatch::Set(session_id.to_string()),
            work_item_id: OptionalFieldPatch::Set(work_item_id.to_string()),
            ..TaskBoardItemPatch::default()
        },
    )
}

fn new_workflow_execution_id() -> String {
    format!("workflow-{}", uuid::Uuid::new_v4().simple())
}

fn new_policy_trace_id() -> String {
    format!("policy-trace-{}", uuid::Uuid::new_v4().simple())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn seed_item(board: &TaskBoardStore, id: &str, project_type: Option<&str>) {
        let mut item = TaskBoardItem::new(
            id.into(),
            id.into(),
            String::new(),
            "2026-05-15T00:00:00Z".into(),
        );
        item.status = TaskBoardStatus::Todo;
        if let Some(project_type) = project_type {
            item.target_project_types = vec![project_type.into()];
        }
        board.create(id, "", item).expect("create board item");
    }

    #[test]
    fn dispatch_drops_items_that_target_other_project_types() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("board");
        let board = TaskBoardStore::new(root.clone());
        seed_item(&board, "matches", Some("web"));
        seed_item(&board, "mismatches", Some("data"));
        seed_item(&board, "wildcard", None);

        let registry = MachineRegistry::new(root.clone());
        let mut local = registry.ensure_local().expect("ensure local");
        local.project_types = vec!["web".into()];
        registry.upsert(&local).expect("declare project types");

        let response = dispatch_task_board(
            &TaskBoardDispatchRequest {
                item_id: None,
                status: Some(TaskBoardStatus::Todo),
                dry_run: true,
                project_dir: None,
                actor: None,
            },
            None,
            &board,
        )
        .expect("dispatch");

        let ids: Vec<&str> = response
            .plans
            .iter()
            .map(|plan| plan.board_item_id.as_str())
            .collect();
        assert!(ids.contains(&"matches"));
        assert!(ids.contains(&"wildcard"));
        assert!(
            !ids.contains(&"mismatches"),
            "dispatch must skip items that target other project_types"
        );
    }
}
