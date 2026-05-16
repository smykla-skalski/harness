use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::protocol::{
    SessionDetail, SessionStartRequest, TaskBoardDispatchRequest, TaskBoardDispatchResponse,
    TaskCreateRequest,
};
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
use crate::task_board::{
    DispatchAppliedTask, DispatchExecutionSummary, DispatchFailure, DispatchFailureKind,
    DispatchPlan, SessionIntent, TaskBoardItem, TaskBoardStatus, TaskBoardStore,
    TaskBoardWorkflowStatus, build_dispatch_summary_with_policy_root, filter_for_local_machine,
    machine_mismatch_plan_with_policy_root,
};

use super::super::{
    create_task, create_task_async, start_session_direct, start_session_direct_async,
};

/// Build dispatch plans for task-board items.
///
/// Per-plan failures are collected into the response rather than short-circuiting
/// the loop; callers see both `applied` and `failures` for partial-rollback handling.
///
/// # Errors
/// Returns `CliError` only when board items cannot be loaded up front.
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
    board: &TaskBoardStore,
) -> Result<TaskBoardDispatchResponse, CliError> {
    let plans = build_dispatch_plans_for_request(board, request)?;
    if request.dry_run {
        return Ok(DispatchExecutionSummary::dry_run(plans));
    }
    let mut applied = Vec::new();
    let mut failures = Vec::new();
    for plan in plans.iter().filter(|plan| plan.is_ready()) {
        match apply_dispatch_plan_async(request, async_db, board, plan).await {
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

fn selected_items(
    board: &TaskBoardStore,
    request: &TaskBoardDispatchRequest,
) -> Result<Vec<TaskBoardItem>, CliError> {
    request.item_id.as_deref().map_or_else(
        || board.list(request.status),
        |item_id| board.get(item_id).map(|item| vec![item]),
    )
}

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
    board: &TaskBoardStore,
    plan: &DispatchPlan,
) -> Result<DispatchAppliedTask, (DispatchFailureKind, CliError)> {
    let actor = dispatch_actor(request);
    let session_id = dispatch_session_id_async(request, async_db, plan)
        .await
        .map_err(|error| (DispatchFailureKind::CreateSession, error))?;
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
    .await
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

/// Undo the patch applied by [`link_dispatched_item`] when downstream wiring
/// (worker spawn) fails. Resets status to `Todo`, clears the session/task link,
/// and marks the workflow as failed so the row does not appear orphaned in
/// `InProgress`.
///
/// # Errors
/// Returns `CliError` if the board update fails.
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

fn new_workflow_execution_id() -> String {
    format!("workflow-{}", uuid::Uuid::new_v4().simple())
}

fn new_policy_trace_id() -> String {
    format!("policy-trace-{}", uuid::Uuid::new_v4().simple())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::planning::{approve_plan, submit_plan};
    use crate::task_board::{DispatchBlockReason, DispatchReadiness, MachineRegistry};
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

    fn seed_ready_item(board: &TaskBoardStore, id: &str) {
        let mut item = TaskBoardItem::new(
            id.into(),
            id.into(),
            String::new(),
            "2026-05-15T00:00:00Z".into(),
        );
        item.status = TaskBoardStatus::Todo;
        let item = submit_plan(&item, "Plan summary").apply_to(&item);
        let item = approve_plan(&item, "lead", "2026-05-15T00:00:00Z").apply_to(&item);
        board.create(id, "", item).expect("create board item");
    }

    #[test]
    fn dispatch_surfaces_machine_mismatch_for_other_project_types() {
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
        assert!(ids.contains(&"mismatches"));

        let mismatched = response
            .plans
            .iter()
            .find(|plan| plan.board_item_id == "mismatches")
            .expect("mismatched plan present");
        match &mismatched.readiness {
            DispatchReadiness::Blocked {
                reason: DispatchBlockReason::MachineMismatch { required, declared },
            } => {
                assert_eq!(required, &vec!["data".to_string()]);
                assert_eq!(declared, &vec!["web".to_string()]);
            }
            other => panic!("expected machine_mismatch, got {other:?}"),
        }
    }

    #[test]
    fn dispatch_collects_per_plan_failures_without_short_circuit() {
        // Two ready plans, no project_dir on the request. Each plan tries to
        // create a session and fails on the missing project_dir gate; the loop
        // must surface both failures instead of bailing on the first.
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("board");
        let board = TaskBoardStore::new(root);
        seed_ready_item(&board, "ready-1");
        seed_ready_item(&board, "ready-2");

        let response = dispatch_task_board(
            &TaskBoardDispatchRequest {
                item_id: None,
                status: Some(TaskBoardStatus::Todo),
                dry_run: false,
                project_dir: None,
                actor: None,
            },
            None,
            &board,
        )
        .expect("dispatch should not short-circuit");

        assert!(
            response.applied.is_empty(),
            "no plan can succeed without project_dir; got applied: {:?}",
            response.applied
        );
        let failure_ids: Vec<&str> = response
            .failures
            .iter()
            .map(|failure| failure.board_item_id.as_str())
            .collect();
        assert!(failure_ids.contains(&"ready-1"));
        assert!(failure_ids.contains(&"ready-2"));
        for failure in &response.failures {
            assert_eq!(failure.kind, DispatchFailureKind::CreateSession);
            assert!(!failure.message.is_empty());
        }
    }

    #[test]
    fn unlink_dispatched_item_clears_session_and_marks_workflow_failed() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("board");
        let board = TaskBoardStore::new(root);
        seed_ready_item(&board, "linked-1");

        // Simulate the link patch by directly applying the same write the
        // dispatch loop would have made; this avoids depending on a working
        // session creation path inside the test.
        let plan = build_dispatch_summary_with_policy_root(
            &[board.get("linked-1").expect("seed item")],
            board.root(),
        )
        .into_iter()
        .next()
        .expect("plan");
        let linked = link_dispatched_item(&board, &plan, "session-x", "work-x")
            .expect("link dispatched item");
        assert_eq!(linked.status, TaskBoardStatus::InProgress);
        assert_eq!(linked.session_id.as_deref(), Some("session-x"));
        assert_eq!(linked.work_item_id.as_deref(), Some("work-x"));

        let undone = unlink_dispatched_item(&board, "linked-1", "worker spawn failed")
            .expect("unlink dispatched item");
        assert_eq!(undone.status, TaskBoardStatus::Todo);
        assert!(undone.session_id.is_none());
        assert!(undone.work_item_id.is_none());
        assert_eq!(undone.workflow.status, TaskBoardWorkflowStatus::Failed);
        assert_eq!(
            undone.workflow.last_error.as_deref(),
            Some("worker spawn failed")
        );
        assert_eq!(
            undone.workflow.current_step_id.as_deref(),
            Some("worker_spawn")
        );
    }
}
