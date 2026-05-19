use tokio::runtime::Builder as TokioRuntimeBuilder;
use uuid::Uuid;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::protocol::{
    TaskBoardAuditRequest, TaskBoardAuditResponse, TaskBoardCatalogRequest,
    TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest, TaskBoardDispatchRequest,
    TaskBoardDispatchResponse, TaskBoardGetItemRequest, TaskBoardListItemsRequest,
    TaskBoardListItemsResponse, TaskBoardMachinesResponse, TaskBoardPlanApproveRequest,
    TaskBoardPlanBeginRequest, TaskBoardPlanRevokeRequest, TaskBoardPlanSubmitRequest,
    TaskBoardPlanningResponse, TaskBoardPolicyPipelineAuditResponse,
    TaskBoardPolicyPipelinePromoteRequest, TaskBoardPolicyPipelinePromoteResponse,
    TaskBoardPolicyPipelineResponse, TaskBoardPolicyPipelineSaveDraftRequest,
    TaskBoardPolicyPipelineSaveDraftResponse, TaskBoardPolicyPipelineSimulateRequest,
    TaskBoardPolicyPipelineSimulationResponse, TaskBoardProjectsResponse, TaskBoardSyncRequest,
    TaskBoardSyncResponse, TaskBoardUpdateItemRequest,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
use crate::task_board::{
    ExternalProvider, ExternalSyncClient, ExternalSyncConfig, ExternalSyncDirection,
    ExternalSyncOptions, PolicyPipelineStore, TaskBoardItem, TaskBoardOrchestrator, TaskBoardStore,
    build_audit_summary, build_machine_summaries, build_project_summaries, build_sync_summary,
    configured_sync_clients, default_board_root, sync_external_tasks,
};
use crate::task_board::{
    PlanningTransition, approve_plan, begin_planning, revoke_plan, submit_plan,
};
use crate::workspace::utc_now;

use super::task_board_runtime::external_sync_config_for_repository;

mod dispatch;

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

/// Move an item back into planning and clear prior approval.
///
/// # Errors
/// Returns `CliError` when the item cannot be loaded or persisted.
pub fn begin_task_board_planning(
    request: &TaskBoardPlanBeginRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    apply_planning_transition(&request.id, begin_planning)
}

/// Submit a semantic plan summary for review.
///
/// # Errors
/// Returns `CliError` when the item cannot be loaded or persisted.
pub fn submit_task_board_plan(
    request: &TaskBoardPlanSubmitRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    apply_planning_transition(&request.id, |item| submit_plan(item, &request.summary))
}

/// Approve the current semantic plan and move the item to ready work.
///
/// # Errors
/// Returns `CliError` when the item cannot be loaded or persisted.
pub fn approve_task_board_plan(
    request: &TaskBoardPlanApproveRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    let approved_at = request.approved_at.clone().unwrap_or_else(utc_now);
    apply_planning_transition(&request.id, |item| {
        approve_plan(item, &request.approved_by, &approved_at)
    })
}

/// Revoke a previously granted plan approval and bounce the item back to
/// `PlanReview` while keeping the plan summary intact.
///
/// # Errors
/// Returns `CliError` when the item cannot be loaded or persisted.
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
pub fn sync_task_board(request: &TaskBoardSyncRequest) -> Result<TaskBoardSyncResponse, CliError> {
    run_task_board_sync_blocking(request)
}

/// Run external sync through configured provider clients.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded, provider clients
/// cannot be built, or an applied provider operation fails.
pub async fn sync_task_board_async(
    request: &TaskBoardSyncRequest,
) -> Result<TaskBoardSyncResponse, CliError> {
    sync_task_board_async_with_config(request, active_external_sync_config()).await
}

pub(crate) async fn sync_task_board_async_with_config(
    request: &TaskBoardSyncRequest,
    config: ExternalSyncConfig,
) -> Result<TaskBoardSyncResponse, CliError> {
    let board = store();
    let clients = configured_sync_clients(&config, request.provider)?;
    tracing::info!(
        provider = ?request.provider,
        direction = ?request.direction,
        dry_run = request.dry_run,
        status = ?request.status,
        client_count = clients.len(),
        github_token_configured = config.token_for(ExternalProvider::GitHub).is_some(),
        github_repository_configured = config.github_repository().is_some(),
        github_inbox_repositories = config.github_inbox_repositories().len(),
        todoist_token_configured = config.token_for(ExternalProvider::Todoist).is_some(),
        "task-board sync requested"
    );
    ensure_sync_request_can_run(request, &config, &clients)?;
    let operations = sync_external_tasks(&board, sync_options(request), &clients).await?;
    let items = board.list(request.status)?;
    let mut summary = build_sync_summary(&items, &config);
    summary.operations = operations;
    tracing::info!(
        total = summary.total,
        providers = summary.providers.len(),
        operations = summary.operations.len(),
        "task-board sync completed"
    );
    Ok(summary)
}

/// List project summaries for task-board items.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded.
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
    let board = store();
    dispatch::dispatch_task_board_async(request, async_db, &board).await
}

/// Roll back the link patch applied to a dispatched item when a downstream
/// stage (worker spawn) fails. Resets status to `Todo` + clears the session
/// and task link so the row is not orphaned in `InProgress`.
///
/// # Errors
/// Returns `CliError` when the board item cannot be reloaded or persisted.
pub(crate) fn unlink_dispatched_task_board_item(
    board_item_id: &str,
    reason: &str,
) -> Result<TaskBoardItem, CliError> {
    dispatch::unlink_dispatched_item(&store(), board_item_id, reason)
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

/// Load the V2 task-board policy pipeline, seeding the default graph when absent.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be loaded.
pub fn task_board_policy_pipeline() -> Result<TaskBoardPolicyPipelineResponse, CliError> {
    policy_store().load_or_seed()
}

/// Save a V2 policy pipeline draft.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub fn save_task_board_policy_pipeline_draft(
    request: &TaskBoardPolicyPipelineSaveDraftRequest,
) -> Result<TaskBoardPolicyPipelineSaveDraftResponse, CliError> {
    policy_store().save_draft(request.document.clone(), request.if_revision)
}

/// Simulate a V2 policy pipeline in dry-run mode.
///
/// # Errors
/// Returns `CliError` when simulation state cannot be written.
pub fn simulate_task_board_policy_pipeline(
    request: &TaskBoardPolicyPipelineSimulateRequest,
) -> Result<TaskBoardPolicyPipelineSimulationResponse, CliError> {
    policy_store().simulate(request.document.clone())
}

/// Promote a simulated V2 policy pipeline for enforcement.
///
/// # Errors
/// Returns `CliError` when simulation is missing/stale or promotion cannot be persisted.
pub fn promote_task_board_policy_pipeline(
    request: &TaskBoardPolicyPipelinePromoteRequest,
) -> Result<TaskBoardPolicyPipelinePromoteResponse, CliError> {
    policy_store().promote(request)
}

/// Summarize V2 policy pipeline audit state.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be loaded.
pub fn audit_task_board_policy_pipeline() -> Result<TaskBoardPolicyPipelineAuditResponse, CliError>
{
    policy_store().audit_summary()
}

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

fn optional_string_patch(value: Option<&String>, clear: bool) -> OptionalFieldPatch<String> {
    if clear {
        return OptionalFieldPatch::Clear;
    }
    value
        .cloned()
        .map_or(OptionalFieldPatch::Unchanged, OptionalFieldPatch::Set)
}

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

fn store() -> TaskBoardStore {
    TaskBoardStore::new(default_board_root())
}

fn policy_store() -> PolicyPipelineStore {
    PolicyPipelineStore::new(default_board_root())
}

fn run_task_board_sync_blocking(
    request: &TaskBoardSyncRequest,
) -> Result<TaskBoardSyncResponse, CliError> {
    run_task_board_sync_blocking_with_config(request, active_external_sync_config())
}

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

fn sync_options(request: &TaskBoardSyncRequest) -> ExternalSyncOptions {
    ExternalSyncOptions {
        status: request.status,
        provider: request.provider,
        direction: request.direction,
        conflict_policy: request.conflict_policy,
        dry_run: request.dry_run,
    }
}

fn ensure_sync_request_can_run(
    request: &TaskBoardSyncRequest,
    config: &ExternalSyncConfig,
    clients: &[Box<dyn ExternalSyncClient>],
) -> Result<(), CliError> {
    if clients.is_empty()
        || clients
            .iter()
            .any(|client| client_can_run(request, client.as_ref()))
    {
        return Ok(());
    }
    let message = sync_request_unavailable_message(request, config);
    tracing::warn!(%message, "task-board sync cannot run");
    Err(CliErrorKind::workflow_io(message).into())
}

fn client_can_run(request: &TaskBoardSyncRequest, client: &dyn ExternalSyncClient) -> bool {
    if request
        .provider
        .is_some_and(|provider| provider != client.provider())
    {
        return false;
    }
    match request.direction {
        ExternalSyncDirection::Pull => client.allows_pull(),
        ExternalSyncDirection::Push => client.allows_push(),
        ExternalSyncDirection::Both => client.allows_pull() || client.allows_push(),
    }
}

fn sync_request_unavailable_message(
    request: &TaskBoardSyncRequest,
    config: &ExternalSyncConfig,
) -> String {
    if matches!(
        request.direction,
        ExternalSyncDirection::Pull | ExternalSyncDirection::Both
    ) && request
        .provider
        .is_none_or(|provider| provider == ExternalProvider::GitHub)
        && config.token_for(ExternalProvider::GitHub).is_some()
        && config.github_repository().is_none()
        && config.github_inbox_repositories().is_empty()
    {
        return "GitHub pull sync requires a configured repository or inbox repository. \
Set Task Board GitHub owner/repo or add a GitHub inbox repository in Settings."
            .to_string();
    }
    format!(
        "task-board {:?} sync has no configured {:?} provider client",
        request.direction, request.provider
    )
}

fn new_task_id() -> String {
    format!("task-{}", Uuid::new_v4().simple())
}
