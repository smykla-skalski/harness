#[cfg(test)]
use tokio::runtime::Builder as TokioRuntimeBuilder;
#[cfg(test)]
use uuid::Uuid;

use crate::daemon::db::AsyncDaemonDb;
#[cfg(test)]
use crate::daemon::db::DaemonDb;
#[cfg(test)]
use crate::daemon::protocol::{
    TaskBoardAuditRequest, TaskBoardAuditResponse, TaskBoardCatalogRequest,
    TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest, TaskBoardGetItemRequest,
    TaskBoardListItemsRequest, TaskBoardListItemsResponse, TaskBoardMachinesResponse,
    TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest, TaskBoardPlanRevokeRequest,
    TaskBoardPlanSubmitRequest, TaskBoardPlanningResponse, TaskBoardProjectsResponse,
    TaskBoardSyncRequest, TaskBoardSyncResponse, TaskBoardUpdateItemRequest,
};
use crate::daemon::protocol::{TaskBoardDispatchRequest, TaskBoardDispatchResponse};
use crate::errors::CliError;
#[cfg(test)]
use crate::errors::CliErrorKind;
#[cfg(test)]
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
#[cfg(test)]
use crate::task_board::{
    ExternalSyncConfig, ExternalSyncOperation, TaskBoardItem, TaskBoardOrchestrator,
    TaskBoardStore, build_audit_summary, build_machine_summaries, build_project_summaries,
    configured_sync_clients, default_board_root, sync_external_tasks,
};
#[cfg(test)]
use crate::task_board::{
    PlanningTransition, approve_plan, begin_planning, revoke_plan, submit_plan,
};
#[cfg(test)]
use crate::workspace::utc_now;
#[cfg(test)]
use tokio::task::spawn_blocking;

#[cfg(test)]
use self::sync::build_sync_response;
pub(crate) use self::sync::{
    build_sync_response_from_items, ensure_sync_request_can_run, log_sync_completion,
    log_sync_request, sync_options,
};
#[cfg(test)]
use super::task_board_runtime::external_sync_config_for_repository;

mod dispatch;
mod dispatch_preparation;
mod policy_canvas;
mod policy_canvas_io;
mod policy_canvas_response;
mod sync;

pub(crate) use dispatch_preparation::prepare_claimed_task_board_dispatch;

pub(crate) use policy_canvas::{
    audit_policy_pipeline, create_policy_canvas, create_policy_scenario, delete_policy_canvas,
    delete_policy_scenario, duplicate_policy_canvas, go_live_diff_policy_pipeline,
    make_live_policy_pipeline, policy_canvas_workspace, policy_pipeline, promote_policy_pipeline,
    rename_policy_canvas, replay_policy_pipeline, reset_policy_scenarios,
    save_policy_pipeline_draft, set_active_policy_canvas, set_policy_canvas_global_enforcement,
    simulate_policy_pipeline, update_policy_scenario,
};
pub(crate) use policy_canvas_io::{export_policy, import_policy};

/// Create a persisted task-board item.
///
/// # Errors
/// Returns `CliError` when the generated or supplied ID is unsafe, already
/// exists, or the markdown item cannot be written.
#[cfg(test)]
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
    item.target_project_types
        .clone_from(&request.target_project_types);
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
#[cfg(test)]
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
#[cfg(test)]
pub fn get_task_board_item(request: &TaskBoardGetItemRequest) -> Result<TaskBoardItem, CliError> {
    store().get(&request.id)
}

/// Update one task-board item.
///
/// # Errors
/// Returns `CliError` when the item cannot be loaded or the patched item cannot
/// be written.
#[cfg(test)]
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
#[cfg(test)]
pub fn delete_task_board_item(
    request: &TaskBoardDeleteItemRequest,
) -> Result<TaskBoardItem, CliError> {
    store().delete(&request.id)
}

/// Move an item back into planning and clear prior approval.
///
/// # Errors
/// Returns `CliError` when the item cannot be loaded or persisted.
#[cfg(test)]
pub fn begin_task_board_planning(
    request: &TaskBoardPlanBeginRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    apply_planning_transition(&request.id, begin_planning)
}

/// Submit a semantic plan summary for review.
///
/// # Errors
/// Returns `CliError` when the item cannot be loaded or persisted.
#[cfg(test)]
pub fn submit_task_board_plan(
    request: &TaskBoardPlanSubmitRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    apply_planning_transition(&request.id, |item| submit_plan(item, &request.summary))
}

/// Approve the current semantic plan and move the item to ready work.
///
/// # Errors
/// Returns `CliError` when the item cannot be loaded or persisted.
#[cfg(test)]
pub fn approve_task_board_plan(
    request: &TaskBoardPlanApproveRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    let approved_at = request.approved_at.clone().unwrap_or_else(utc_now);
    apply_planning_transition(&request.id, |item| {
        approve_plan(item, &request.approved_by, &approved_at)
    })
}

/// Revoke a previously granted plan approval and bounce the item back to
/// agentic review while keeping the plan summary intact.
///
/// # Errors
/// Returns `CliError` when the item cannot be loaded or persisted.
#[cfg(test)]
pub fn revoke_task_board_plan(
    request: &TaskBoardPlanRevokeRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    let actor = request.actor.as_deref();
    let board = store();
    let current = board.get(&request.id)?;
    let transition = revoke_plan(&current, actor);
    let item = board.update(
        &request.id,
        TaskBoardItemPatch {
            status: Some(transition.to_status),
            planning: Some(transition.planning.clone()),
            clear_approval: true,
            ..TaskBoardItemPatch::default()
        },
    )?;
    Ok(TaskBoardPlanningResponse { transition, item })
}

/// Preview or apply external sync for local task-board items.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded or sync execution fails.
#[cfg(test)]
pub fn sync_task_board(request: &TaskBoardSyncRequest) -> Result<TaskBoardSyncResponse, CliError> {
    run_task_board_sync_blocking(request)
}

/// Run external sync through configured provider clients.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded, provider clients
/// cannot be built, or an applied provider operation fails.
#[cfg(test)]
pub async fn sync_task_board_async(
    request: &TaskBoardSyncRequest,
) -> Result<TaskBoardSyncResponse, CliError> {
    let config = active_external_sync_config_async().await?;
    sync_task_board_async_with_config(request, config).await
}

#[cfg(test)]
pub(crate) async fn sync_task_board_async_with_config(
    request: &TaskBoardSyncRequest,
    config: ExternalSyncConfig,
) -> Result<TaskBoardSyncResponse, CliError> {
    let board = store();
    let clients = configured_sync_clients(&config, request.provider)?;
    log_sync_request(request, &config, clients.len());
    ensure_sync_request_can_run(request, &config, &clients)?;
    let operations = sync_external_tasks(&board, sync_options(request), &clients).await?;
    let summary = build_sync_response_async(&board, request, config.clone(), operations).await?;
    log_sync_completion(&summary);
    Ok(summary)
}

/// List project summaries for task-board items.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded.
#[cfg(test)]
pub fn list_task_board_projects(
    request: &TaskBoardCatalogRequest,
) -> Result<TaskBoardProjectsResponse, CliError> {
    let items = store().list(request.status)?;
    Ok(build_project_summaries(&items))
}

/// List machine summaries for task-board items.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded.
#[cfg(test)]
pub fn list_task_board_machines(
    request: &TaskBoardCatalogRequest,
) -> Result<TaskBoardMachinesResponse, CliError> {
    let items = store().list(request.status)?;
    Ok(build_machine_summaries(&items))
}

/// Build dispatch plans for task-board items.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded.
#[cfg(test)]
pub fn dispatch_task_board(
    request: &TaskBoardDispatchRequest,
    db: Option<&DaemonDb>,
) -> Result<TaskBoardDispatchResponse, CliError> {
    let board = store();
    dispatch::dispatch_task_board(request, db, &board)
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
    dispatch::dispatch_task_board_async(request, async_db).await
}

pub(crate) async fn pick_task_board_dispatch_async(
    async_db: &AsyncDaemonDb,
) -> Result<crate::daemon::protocol::TaskBoardDispatchPickResponse, CliError> {
    dispatch::pick_task_board_dispatch_async(async_db).await
}

/// Build task-board audit counts.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded.
#[cfg(test)]
pub fn audit_task_board(
    request: &TaskBoardAuditRequest,
) -> Result<TaskBoardAuditResponse, CliError> {
    let items = store().list(request.status)?;
    Ok(build_audit_summary(&items))
}

#[cfg(test)]
fn patch_from_request(request: &TaskBoardUpdateItemRequest) -> TaskBoardItemPatch {
    TaskBoardItemPatch {
        title: request.title.clone(),
        body: request.body.clone(),
        status: request.status,
        priority: request.priority,
        tags: request.tags.clone(),
        project_id: optional_string_patch(
            request.project_id.as_ref(),
            request.clear_identity.clear_project_id,
        ),
        target_project_types: request.target_project_types.clone(),
        agent_mode: request.agent_mode,
        external_refs: request.external_refs.clone(),
        planning: request.planning.clone(),
        clear_planning: request.clear_state.clear_planning,
        clear_approval: false,
        workflow: request.workflow.clone(),
        clear_workflow: request.clear_state.clear_workflow,
        session_id: optional_string_patch(
            request.session_id.as_ref(),
            request.clear_identity.clear_session_id,
        ),
        work_item_id: optional_string_patch(
            request.work_item_id.as_ref(),
            request.clear_identity.clear_work_item_id,
        ),
    }
}

#[cfg(test)]
fn optional_string_patch(value: Option<&String>, clear: bool) -> OptionalFieldPatch<String> {
    if clear {
        return OptionalFieldPatch::Clear;
    }
    value
        .cloned()
        .map_or(OptionalFieldPatch::Unchanged, OptionalFieldPatch::Set)
}

#[cfg(test)]
fn apply_planning_transition(
    id: &str,
    transition_for: impl FnOnce(&TaskBoardItem) -> PlanningTransition,
) -> Result<TaskBoardPlanningResponse, CliError> {
    let board = store();
    let current = board.get(id)?;
    let transition = transition_for(&current);
    let item = board.update(
        id,
        TaskBoardItemPatch {
            status: Some(transition.to_status),
            planning: Some(transition.planning.clone()),
            ..TaskBoardItemPatch::default()
        },
    )?;
    Ok(TaskBoardPlanningResponse { transition, item })
}

#[cfg(test)]
fn store() -> TaskBoardStore {
    TaskBoardStore::new(default_board_root())
}

#[cfg(test)]
fn run_task_board_sync_blocking(
    request: &TaskBoardSyncRequest,
) -> Result<TaskBoardSyncResponse, CliError> {
    run_task_board_sync_blocking_with_config(request, active_external_sync_config())
}

#[cfg(test)]
fn active_external_sync_config() -> ExternalSyncConfig {
    let settings = TaskBoardOrchestrator::new(default_board_root())
        .settings()
        .ok();
    let (repository, inbox_repositories, github_labels, todoist_projects) = settings.map_or_else(
        || (None, Vec::new(), Vec::new(), Vec::new()),
        |settings| {
            let project = &settings.github_project;
            let repository = (!project.owner.trim().is_empty() && !project.repo.trim().is_empty())
                .then(|| project.repository_slug());
            (
                repository,
                settings.github_inbox.repositories.clone(),
                settings.github_inbox.label_filter.clone(),
                settings.todoist_inbox.project_filter.clone(),
            )
        },
    );
    external_sync_config_for_repository(repository.as_deref(), &inbox_repositories)
        .with_github_import_labels_override(&github_labels)
        .with_todoist_import_project_ids_override(&todoist_projects)
}

#[cfg(test)]
async fn active_external_sync_config_async() -> Result<ExternalSyncConfig, CliError> {
    run_task_board_service_blocking("load external sync config", || {
        Ok(active_external_sync_config())
    })
    .await
}

#[cfg(test)]
async fn build_sync_response_async(
    board: &TaskBoardStore,
    request: &TaskBoardSyncRequest,
    config: ExternalSyncConfig,
    operations: Vec<ExternalSyncOperation>,
) -> Result<TaskBoardSyncResponse, CliError> {
    let board = board.clone();
    let request = request.clone();
    run_task_board_service_blocking("build sync response", move || {
        build_sync_response(&board, &request, &config, operations)
    })
    .await
}

#[cfg(test)]
pub(crate) fn run_task_board_sync_blocking_with_config(
    request: &TaskBoardSyncRequest,
    config: ExternalSyncConfig,
) -> Result<TaskBoardSyncResponse, CliError> {
    TokioRuntimeBuilder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("create task-board sync runtime: {error}"))
        })?
        .block_on(sync_task_board_async_with_config(request, config))
}

#[cfg(test)]
async fn run_task_board_service_blocking<T, F>(
    operation: &'static str,
    work: F,
) -> Result<T, CliError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, CliError> + Send + 'static,
{
    spawn_blocking(work).await.unwrap_or_else(|error| {
        Err(CliErrorKind::workflow_io(format!(
            "task-board service {operation} worker failed: {error}"
        ))
        .into())
    })
}

#[cfg(test)]
fn new_task_id() -> String {
    format!("task-{}", Uuid::new_v4().simple())
}
