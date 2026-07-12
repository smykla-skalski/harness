use crate::daemon::db::AsyncDaemonDb;
#[cfg(test)]
use crate::daemon::db::DaemonDb;
#[cfg(test)]
use crate::daemon::protocol::{SessionDetail, SessionStartRequest, TaskCreateRequest};
use crate::daemon::protocol::{TaskBoardDispatchRequest, TaskBoardDispatchResponse};
use crate::errors::CliError;
#[cfg(test)]
use crate::errors::CliErrorKind;
#[cfg(test)]
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
#[cfg(test)]
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
use crate::task_board::{
    DispatchAppliedTask, DispatchExecutionSummary, DispatchFailure, DispatchFailureKind,
    DispatchPlan, Machine, TaskBoardItem, build_dispatch_plans_with_policy,
    machine_mismatch_plan_with_policy,
};
#[cfg(test)]
use crate::task_board::{
    SessionIntent, TaskBoardStatus, TaskBoardStore, TaskBoardWorkflowStatus,
    build_dispatch_summary_with_policy_root, filter_for_local_machine,
    machine_mismatch_plan_with_policy_root,
};

use super::super::task_board_db::task_board_host_local_db;
#[cfg(test)]
use super::super::{create_task, start_session_direct};
use super::dispatch_preparation::reserve_and_prepare_task_board_dispatch;

/// Build dispatch plans for task-board items.
///
/// Per-plan failures are collected into the response rather than short-circuiting
/// the loop; callers see both `applied` and `failures` for partial-rollback handling.
///
/// # Errors
/// Returns `CliError` only when board items cannot be loaded up front.
#[cfg(test)]
pub fn dispatch_task_board(
    request: &TaskBoardDispatchRequest,
    db: Option<&DaemonDb>,
    board: &TaskBoardStore,
) -> Result<TaskBoardDispatchResponse, CliError> {
    let plans = build_dispatch_plans_for_request(board, request)?;
    if request.dry_run {
        return Ok(DispatchExecutionSummary::dry_run(plans));
    }
    let mut applied = Vec::new();
    let mut failures = Vec::new();
    for plan in plans.iter().filter(|plan| plan.is_ready()) {
        match apply_dispatch_plan(request, db, board, plan) {
            Ok(task) => applied.push(task),
            Err((kind, error)) => {
                failures.push(DispatchFailure {
                    board_item_id: plan.board_item_id.clone(),
                    kind,
                    message: error.to_string(),
                });
            }
        }
    }
    Ok(DispatchExecutionSummary {
        plans,
        applied,
        failures,
    })
}

/// Execute ready dispatch plans for task-board items through the async daemon DB.
///
/// Per-plan failures are collected into the response rather than short-circuiting
/// the loop; callers see both `applied` and `failures` for partial-rollback handling.
///
/// # Errors
/// Returns `CliError` only when board items cannot be loaded up front.
pub async fn dispatch_task_board_async(
    request: &TaskBoardDispatchRequest,
    async_db: &AsyncDaemonDb,
) -> Result<TaskBoardDispatchResponse, CliError> {
    let plans = build_dispatch_plans_for_request_async(async_db, request).await?;
    if request.dry_run {
        return Ok(DispatchExecutionSummary::dry_run(plans));
    }
    let mut applied = Vec::new();
    let mut failures = Vec::new();
    for plan in plans.iter().filter(|plan| plan.is_ready()) {
        match apply_dispatch_plan_async(request, async_db, plan).await {
            Ok(task) => applied.push(task),
            Err((kind, error)) => {
                failures.push(DispatchFailure {
                    board_item_id: plan.board_item_id.clone(),
                    kind,
                    message: error.to_string(),
                });
            }
        }
    }
    Ok(DispatchExecutionSummary {
        plans,
        applied,
        failures,
    })
}

#[cfg(test)]
fn build_dispatch_plans_for_request(
    board: &TaskBoardStore,
    request: &TaskBoardDispatchRequest,
) -> Result<Vec<DispatchPlan>, CliError> {
    let items = selected_items(board, request)?;
    let (kept, rejected) = filter_for_local_machine(items, board);
    let mut plans = build_dispatch_summary_with_policy_root(&kept, board.root());
    plans.extend(rejected.iter().map(|(item, machine)| {
        machine_mismatch_plan_with_policy_root(item, machine, board.root())
    }));
    Ok(plans)
}

#[cfg(test)]
fn selected_items(
    board: &TaskBoardStore,
    request: &TaskBoardDispatchRequest,
) -> Result<Vec<TaskBoardItem>, CliError> {
    request.item_id.as_deref().map_or_else(
        || board.list(request.status),
        |item_id| board.get(item_id).map(|item| vec![item]),
    )
}

#[cfg(test)]
fn apply_dispatch_plan(
    request: &TaskBoardDispatchRequest,
    db: Option<&DaemonDb>,
    board: &TaskBoardStore,
    plan: &DispatchPlan,
) -> Result<DispatchAppliedTask, (DispatchFailureKind, CliError)> {
    let actor = dispatch_actor(request);
    let session_id = dispatch_session_id(request, db, plan)
        .map_err(|error| (DispatchFailureKind::CreateSession, error))?;
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
    )
    .map_err(|error| (DispatchFailureKind::CreateTask, error))?;
    let work_item_id =
        newest_task_id(detail).map_err(|error| (DispatchFailureKind::CreateTask, error))?;
    let item = link_dispatched_item(board, plan, &session_id, &work_item_id)
        .map_err(|error| (DispatchFailureKind::LinkItem, error))?;
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
    plan: &DispatchPlan,
) -> Result<DispatchAppliedTask, (DispatchFailureKind, CliError)> {
    reserve_and_prepare_task_board_dispatch(async_db, request, plan).await
}

#[cfg(test)]
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

#[cfg(test)]
fn dispatch_actor(request: &TaskBoardDispatchRequest) -> &str {
    request.actor.as_deref().unwrap_or(CONTROL_PLANE_ACTOR_ID)
}

#[cfg(test)]
fn required_dispatch_project_dir(request: &TaskBoardDispatchRequest) -> Result<String, CliError> {
    request.project_dir.clone().ok_or_else(|| {
        CliErrorKind::workflow_io(
            "task-board dispatch requires project_dir when a session must be created",
        )
        .into()
    })
}

#[cfg(test)]
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

#[cfg(test)]
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

/// Undo the patch applied by [`link_dispatched_item`] when downstream wiring
/// (worker spawn) fails. Resets status to `Todo`, clears the session/task link,
/// and marks the workflow as failed so the row does not appear orphaned in
/// `InProgress`.
///
/// # Errors
/// Returns `CliError` if the board update fails.
#[cfg(test)]
pub fn unlink_dispatched_item(
    board: &TaskBoardStore,
    board_item_id: &str,
    reason: &str,
) -> Result<TaskBoardItem, CliError> {
    let current = board.get(board_item_id)?;
    let mut workflow = current.workflow;
    workflow.status = TaskBoardWorkflowStatus::Failed;
    workflow.current_step_id = Some("worker_spawn".to_string());
    workflow.last_error = Some(reason.to_string());
    board.update(
        board_item_id,
        TaskBoardItemPatch {
            status: Some(TaskBoardStatus::Todo),
            workflow: Some(workflow),
            session_id: OptionalFieldPatch::Clear,
            work_item_id: OptionalFieldPatch::Clear,
            ..TaskBoardItemPatch::default()
        },
    )
}

async fn build_dispatch_plans_for_request_async(
    db: &AsyncDaemonDb,
    request: &TaskBoardDispatchRequest,
) -> Result<Vec<DispatchPlan>, CliError> {
    let items = if let Some(item_id) = request.item_id.as_deref() {
        vec![db.task_board_item(item_id).await?]
    } else {
        db.list_task_board_items(request.status).await?
    };
    let machine = task_board_host_local_db(db).await.ok();
    let (kept, rejected) = filter_for_machine(items, machine.as_ref());
    let workspace = db.load_policy_workspace().await?;
    let policy = workspace
        .as_ref()
        .and_then(|workspace| workspace.active_live_canvas())
        .map(|(canvas, document)| (canvas.id.as_str(), document));
    let mut plans = build_dispatch_plans_with_policy(&kept, policy);
    plans.extend(
        rejected
            .iter()
            .map(|(item, machine)| machine_mismatch_plan_with_policy(item, machine, policy)),
    );
    Ok(plans)
}

fn filter_for_machine(
    items: Vec<TaskBoardItem>,
    machine: Option<&Machine>,
) -> (Vec<TaskBoardItem>, Vec<(TaskBoardItem, Machine)>) {
    let Some(machine) = machine else {
        return (items, Vec::new());
    };
    let mut kept = Vec::with_capacity(items.len());
    let mut rejected = Vec::new();
    for item in items {
        if machine.accepts_any(&item.target_project_types) {
            kept.push(item);
        } else {
            rejected.push((item, machine.clone()));
        }
    }
    (kept, rejected)
}

#[cfg(test)]
fn new_workflow_execution_id() -> String {
    format!("workflow-{}", uuid::Uuid::new_v4().simple())
}

#[cfg(test)]
fn new_policy_trace_id() -> String {
    format!("policy-trace-{}", uuid::Uuid::new_v4().simple())
}

#[cfg(test)]
mod tests;
