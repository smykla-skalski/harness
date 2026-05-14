use uuid::Uuid;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::protocol::{
    SessionDetail, SessionStartRequest, TaskBoardAuditRequest, TaskBoardAuditResponse,
    TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest, TaskBoardDispatchRequest,
    TaskBoardDispatchResponse, TaskBoardEvaluateRequest, TaskBoardGetItemRequest,
    TaskBoardListItemsRequest, TaskBoardListItemsResponse, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorRunOnceResponse, TaskBoardOrchestratorSettingsResponse,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardOrchestratorStatusResponse,
    TaskBoardSyncRequest, TaskBoardSyncResponse, TaskBoardUpdateItemRequest, TaskCreateRequest,
};
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
use crate::task_board::{
    DispatchAppliedTask, DispatchExecutionSummary, DispatchPlan, ExternalSyncConfig, SessionIntent,
    TaskBoardItem, TaskBoardOrchestrator, TaskBoardOrchestratorDispatchInput,
    TaskBoardOrchestratorTickPhase, TaskBoardStatus, TaskBoardStore, TaskBoardWorkflowStatus,
    build_audit_summary, build_dispatch_summary, build_sync_summary, default_board_root,
};
use crate::workspace::utc_now;

use super::task_board_evaluation::{evaluate_task_board, evaluate_task_board_async};

/// Create a persisted task-board item.
///
/// # Errors
/// Returns `CliError` when the generated or supplied ID is unsafe, already
/// exists, or the markdown item cannot be written.
pub fn create_task_board_item(
    request: &TaskBoardCreateItemRequest,
) -> Result<TaskBoardItem, CliError> {
    let now = utc_now();
    let mut item = TaskBoardItem::new(
        request.id.clone().unwrap_or_else(new_task_id),
        request.title.clone(),
        request.body.clone(),
        now,
    );
    item.priority = request.priority;
    item.agent_mode = request.agent_mode;
    item.tags.clone_from(&request.tags);
    item.project_id.clone_from(&request.project_id);
    item.external_refs.clone_from(&request.external_refs);
    item.planning.clone_from(&request.planning);
    if let Some(workflow) = &request.workflow {
        item.workflow.clone_from(workflow);
    }
    item.session_id.clone_from(&request.session_id);
    item.work_item_id.clone_from(&request.work_item_id);
    store().create(&request.title, &request.body, item)
}

/// List active task-board items.
///
/// # Errors
/// Returns `CliError` when the board directory cannot be read or an item cannot
/// be parsed from markdown.
pub fn list_task_board_items(
    request: &TaskBoardListItemsRequest,
) -> Result<TaskBoardListItemsResponse, CliError> {
    store()
        .list(request.status)
        .map(|items| TaskBoardListItemsResponse { items })
}

/// Load one task-board item.
///
/// # Errors
/// Returns `CliError` when the ID is unsafe, the item is missing, or the
/// markdown/frontmatter payload cannot be parsed.
pub fn get_task_board_item(request: &TaskBoardGetItemRequest) -> Result<TaskBoardItem, CliError> {
    store().get(&request.id)
}

/// Update one task-board item.
///
/// # Errors
/// Returns `CliError` when the item cannot be loaded or the patched item cannot
/// be written.
pub fn update_task_board_item(
    id: &str,
    request: &TaskBoardUpdateItemRequest,
) -> Result<TaskBoardItem, CliError> {
    store().update(id, patch_from_request(request))
}

/// Tombstone one task-board item.
///
/// # Errors
/// Returns `CliError` when the item cannot be loaded or the tombstone cannot be
/// written.
pub fn delete_task_board_item(
    request: &TaskBoardDeleteItemRequest,
) -> Result<TaskBoardItem, CliError> {
    store().delete(&request.id)
}

/// Summarize external sync readiness for local task-board items.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded.
pub fn sync_task_board(request: &TaskBoardSyncRequest) -> Result<TaskBoardSyncResponse, CliError> {
    let items = store().list(request.status)?;
    Ok(build_sync_summary(&items, &ExternalSyncConfig::from_env()))
}

/// Build dispatch plans for task-board items.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded.
pub fn dispatch_task_board(
    request: &TaskBoardDispatchRequest,
    db: Option<&DaemonDb>,
) -> Result<TaskBoardDispatchResponse, CliError> {
    let board = store();
    let items = board.list(request.status)?;
    let plans = build_dispatch_summary(&items);
    if request.dry_run {
        return Ok(DispatchExecutionSummary::dry_run(plans));
    }
    let mut applied = Vec::new();
    for plan in plans.iter().filter(|plan| plan.is_ready()) {
        applied.push(apply_dispatch_plan(request, db, &board, plan)?);
    }
    Ok(DispatchExecutionSummary { plans, applied })
}

/// Execute ready dispatch plans for task-board items through the async daemon DB.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded, a session/task cannot
/// be created, or linked board items cannot be persisted.
pub(crate) async fn dispatch_task_board_async(
    request: &TaskBoardDispatchRequest,
    async_db: &AsyncDaemonDb,
) -> Result<TaskBoardDispatchResponse, CliError> {
    let board = store();
    let items = board.list(request.status)?;
    let plans = build_dispatch_summary(&items);
    if request.dry_run {
        return Ok(DispatchExecutionSummary::dry_run(plans));
    }
    let mut applied = Vec::new();
    for plan in plans.iter().filter(|plan| plan.is_ready()) {
        applied.push(apply_dispatch_plan_async(request, async_db, &board, plan).await?);
    }
    Ok(DispatchExecutionSummary { plans, applied })
}

fn apply_dispatch_plan(
    request: &TaskBoardDispatchRequest,
    db: Option<&DaemonDb>,
    board: &TaskBoardStore,
    plan: &DispatchPlan,
) -> Result<DispatchAppliedTask, CliError> {
    let actor = dispatch_actor(request);
    let session_id = dispatch_session_id(request, db, plan)?;
    let detail = super::create_task(
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
    let detail = super::create_task_async(
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
            let state = super::start_session_direct(
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
            let state = super::start_session_direct_async(
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
    workflow.policy_trace_ids.push(new_policy_trace_id());
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

/// Build task-board audit counts.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded.
pub fn audit_task_board(
    request: &TaskBoardAuditRequest,
) -> Result<TaskBoardAuditResponse, CliError> {
    let items = store().list(request.status)?;
    Ok(build_audit_summary(&items))
}

/// Load task-board orchestrator status from durable JSON state.
///
/// # Errors
/// Returns `CliError` when state, settings, or board items cannot be read.
pub fn task_board_orchestrator_status() -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    orchestrator().status()
}

/// Persist task-board orchestrator start intent.
///
/// # Errors
/// Returns `CliError` when durable state cannot be read or written.
pub fn start_task_board_orchestrator() -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    orchestrator().start()
}

/// Persist task-board orchestrator stop intent.
///
/// # Errors
/// Returns `CliError` when durable state cannot be read or written.
pub fn stop_task_board_orchestrator() -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    orchestrator().stop()
}

/// Load task-board orchestrator settings.
///
/// # Errors
/// Returns `CliError` when settings cannot be read.
pub fn task_board_orchestrator_settings() -> Result<TaskBoardOrchestratorSettingsResponse, CliError>
{
    orchestrator().settings()
}

/// Persist task-board orchestrator settings.
///
/// # Errors
/// Returns `CliError` when settings cannot be read or written.
pub fn update_task_board_orchestrator_settings(
    request: &TaskBoardOrchestratorSettingsUpdateRequest,
) -> Result<TaskBoardOrchestratorSettingsResponse, CliError> {
    orchestrator().update_settings(request)
}

/// Run one task-board orchestrator tick through the sync daemon DB path.
///
/// # Errors
/// Returns `CliError` when summaries, dispatch, or state persistence fails.
pub fn run_task_board_orchestrator_once(
    request: &TaskBoardOrchestratorRunOnceRequest,
    db: Option<&DaemonDb>,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    let orchestrator = orchestrator();
    let prepared = orchestrator.prepare_run(request)?;
    let dispatch = match dispatch_task_board(&dispatch_request_from_input(&prepared.input), db) {
        Ok(dispatch) => dispatch,
        Err(error) => {
            orchestrator.fail_run(&prepared, &error)?;
            return Err(error);
        }
    };
    orchestrator.record_run_phase(&prepared, TaskBoardOrchestratorTickPhase::Evaluation)?;
    let evaluation = match evaluate_task_board(
        &TaskBoardEvaluateRequest {
            status: None,
            dry_run: prepared.input.dry_run,
        },
        db,
    ) {
        Ok(evaluation) => evaluation,
        Err(error) => {
            orchestrator.fail_run(&prepared, &error)?;
            return Err(error);
        }
    };
    orchestrator.complete_run_with_evaluation(prepared, dispatch, Some(evaluation))
}

/// Run one task-board orchestrator tick through the async daemon DB path.
///
/// # Errors
/// Returns `CliError` when summaries, dispatch, or state persistence fails.
pub(crate) async fn run_task_board_orchestrator_once_async(
    request: &TaskBoardOrchestratorRunOnceRequest,
    async_db: &AsyncDaemonDb,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    let orchestrator = orchestrator();
    let prepared = orchestrator.prepare_run(request)?;
    let dispatch_request = dispatch_request_from_input(&prepared.input);
    let dispatch = match dispatch_task_board_async(&dispatch_request, async_db).await {
        Ok(dispatch) => dispatch,
        Err(error) => {
            orchestrator.fail_run(&prepared, &error)?;
            return Err(error);
        }
    };
    orchestrator.record_run_phase(&prepared, TaskBoardOrchestratorTickPhase::Evaluation)?;
    let evaluation = match evaluate_task_board_async(
        &TaskBoardEvaluateRequest {
            status: None,
            dry_run: prepared.input.dry_run,
        },
        async_db,
    )
    .await
    {
        Ok(evaluation) => evaluation,
        Err(error) => {
            orchestrator.fail_run(&prepared, &error)?;
            return Err(error);
        }
    };
    orchestrator.complete_run_with_evaluation(prepared, dispatch, Some(evaluation))
}

fn patch_from_request(request: &TaskBoardUpdateItemRequest) -> TaskBoardItemPatch {
    TaskBoardItemPatch {
        title: request.title.clone(),
        body: request.body.clone(),
        status: request.status,
        priority: request.priority,
        tags: request.tags.clone(),
        project_id: optional_string_patch(request.project_id.as_ref(), request.clear_project_id),
        agent_mode: request.agent_mode,
        external_refs: request.external_refs.clone(),
        planning: request.planning.clone(),
        workflow: request.workflow.clone(),
        session_id: optional_string_patch(request.session_id.as_ref(), request.clear_session_id),
        work_item_id: optional_string_patch(
            request.work_item_id.as_ref(),
            request.clear_work_item_id,
        ),
    }
}

fn optional_string_patch(value: Option<&String>, clear: bool) -> OptionalFieldPatch<String> {
    if clear {
        return OptionalFieldPatch::Clear;
    }
    value
        .cloned()
        .map_or(OptionalFieldPatch::Unchanged, OptionalFieldPatch::Set)
}

fn store() -> TaskBoardStore {
    TaskBoardStore::new(default_board_root())
}

fn orchestrator() -> TaskBoardOrchestrator {
    TaskBoardOrchestrator::new(default_board_root())
}

fn dispatch_request_from_input(
    input: &TaskBoardOrchestratorDispatchInput,
) -> TaskBoardDispatchRequest {
    TaskBoardDispatchRequest {
        status: input.status,
        dry_run: input.dry_run,
        project_dir: input.project_dir.clone(),
        actor: input.actor.clone(),
    }
}

fn new_task_id() -> String {
    format!("task-{}", Uuid::new_v4().simple())
}

fn new_workflow_execution_id() -> String {
    format!("workflow-{}", Uuid::new_v4().simple())
}

fn new_policy_trace_id() -> String {
    format!("policy-trace-{}", Uuid::new_v4().simple())
}
