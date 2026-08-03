use std::env;

use uuid::Uuid;

use crate::daemon::db::{AsyncDaemonDb, ColorEdit, DisplayNameEdit, ProjectEdit};
use crate::daemon::protocol::{
    TaskBoardAuditRequest, TaskBoardAuditResponse, TaskBoardCatalogRequest,
    TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest, TaskBoardGetItemRequest,
    TaskBoardHostListResponse, TaskBoardHostLocalResponse, TaskBoardHostSetProjectTypesRequest,
    TaskBoardHostSetProjectTypesResponse, TaskBoardMachinesResponse, TaskBoardProjectUpdateRequest,
    TaskBoardProjectUpdateResponse, TaskBoardProjectsResponse, TaskBoardSyncCancelResponse,
    TaskBoardSyncRequest, TaskBoardSyncResponse, TaskBoardSyncStatusResponse,
    TaskBoardUpdateItemRequest,
};
use crate::task_board::{
    ExternalSyncConfig, Machine, SpawnGateSwitches, TaskBoardItem, build_audit_summary_with_policy,
    build_machine_summaries, build_project_summaries, build_sync_summary,
};
use crate::workspace::utc_now;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::task_board::load_live_spawn_grants;
use crate::daemon::db::task_board::prelude::*;
use super::task_board_repository_scope::{
    TaskBoardRepositoryScope, scoped_task_board_item_db, scoped_task_board_items_db,
};

pub(crate) use crate::task_board::external::{
    TaskBoardSyncCoordinatorFence, TaskBoardSyncCoordinatorFenceDecision,
};

#[cfg(test)]
mod external_ref_tests;
mod list_items;
mod planning;
mod positions;
mod provider_sync_context_store;
mod provider_sync_exclusion;
mod provider_sync_execution;
#[cfg(test)]
mod provider_sync_execution_isolation_tests;
mod provider_sync_store;
mod request_validation;
mod review_report;
mod reviews_sync;
mod sync_audit;
mod sync_run_context;
mod triage_reads;
mod triage_rules_reads;
mod update_request;
mod workflow_progress;

pub(crate) use list_items::read_task_board_items_db;
pub(crate) use planning::{
    approve_task_board_plan_db, begin_task_board_planning_db, revoke_task_board_plan_db,
    submit_task_board_plan_db,
};
pub(crate) use positions::{
    get_task_board_item_position_snapshot_db, reset_task_board_item_position_db,
    set_task_board_item_position_db,
};
use request_validation::{validate_create_title, validate_estimate, validate_update_estimates};
pub(crate) use review_report::get_task_board_ai_review_report_db;
pub(crate) use reviews_sync::reconcile_shared_review_items_db;
use reviews_sync::shared_review_request_clients;
pub(crate) use sync_audit::{
    ReviewsProjectionAuditSummary, record_reviews_projection_result,
    record_targeted_reviews_projection_result,
};
pub(crate) use sync_run_context::TaskBoardSyncRunContext;
pub(crate) use triage_reads::{
    clear_task_board_triage_override_db, get_task_board_item_triage_current_db,
    get_task_board_item_triage_history_db, set_task_board_triage_override_db,
};
pub(crate) use triage_rules_reads::{
    activate_task_board_triage_rules_db, get_task_board_triage_rules_audit_db,
    get_task_board_triage_rules_draft_db, get_task_board_triage_rules_revisions_db,
    preview_task_board_triage_rules_db, save_task_board_triage_rules_draft_db,
};
use update_request::{apply_update_request, replacement_external_refs};
pub(crate) use workflow_progress::get_task_board_workflow_progress_db;

pub(crate) async fn create_task_board_item_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardCreateItemRequest,
) -> Result<TaskBoardItem, CliError> {
    validate_create_title(&request.title)?;
    validate_estimate("estimated_tokens", request.estimated_tokens)?;
    validate_estimate("estimated_cost_microusd", request.estimated_cost_microusd)?;
    let mut item = TaskBoardItem::new(
        request
            .id
            .clone()
            .unwrap_or_else(|| format!("task-{}", Uuid::new_v4().simple())),
        request.title.clone(),
        request.body.clone(),
        utc_now(),
    );
    if let Some(status) = request.status {
        item.status = status;
    }
    item.priority = request.priority;
    item.agent_mode = request.agent_mode;
    item.workflow_kind = request.workflow_kind;
    item.kind = request.kind.clone();
    item.execution_repository
        .clone_from(&request.execution_repository);
    item.estimated_tokens = request.estimated_tokens;
    item.estimated_cost_microusd = request.estimated_cost_microusd;
    item.tags.clone_from(&request.tags);
    item.project_id.clone_from(&request.project_id);
    item.target_project_types
        .clone_from(&request.target_project_types);
    item.external_refs = replacement_external_refs(&[], &request.external_refs);
    item.planning.clone_from(&request.planning);
    if let Some(workflow) = &request.workflow {
        item.workflow.clone_from(workflow);
    }
    item.session_id.clone_from(&request.session_id);
    item.work_item_id.clone_from(&request.work_item_id);
    TaskBoardRepositoryScope::load(db)
        .await?
        .ensure_item(&item)?;
    let mutation = if request.status.is_some() {
        Box::pin(db.create_task_board_item_at_requested_status(item)).await?
    } else {
        Box::pin(db.create_task_board_item_with_triage(item)).await?
    };
    Ok(mutation.item)
}

pub(crate) async fn get_task_board_item_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardGetItemRequest,
) -> Result<TaskBoardItem, CliError> {
    scoped_task_board_item_db(db, &request.id).await
}

pub(crate) async fn update_task_board_item_db(
    db: &AsyncDaemonDb,
    id: &str,
    request: &TaskBoardUpdateItemRequest,
) -> Result<TaskBoardItem, CliError> {
    validate_update_estimates(request)?;
    scoped_task_board_item_db(db, id).await?;
    super::task_board_completion::validate_linked_task_completion(db, id, request.status).await?;
    let scope = TaskBoardRepositoryScope::load(db).await?;
    let mutation = db
        .update_task_board_item_with_triage(id, |item| {
            apply_update_request(item, request)?;
            scope.ensure_item(item)?;
            Ok(true)
        })
        .await?
        .expect("task-board update always mutates");
    Ok(mutation.item)
}

pub(crate) async fn delete_task_board_item_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardDeleteItemRequest,
) -> Result<TaskBoardItem, CliError> {
    scoped_task_board_item_db(db, &request.id).await?;
    Ok(db.delete_task_board_item(&request.id).await?.item)
}

pub(crate) async fn audit_task_board_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardAuditRequest,
) -> Result<TaskBoardAuditResponse, CliError> {
    let items = scoped_task_board_items_db(db, request.status).await?;
    let workspace = db.load_policy_workspace().await?;
    let policy = workspace
        .as_ref()
        .and_then(|workspace| workspace.active_live_canvas())
        .map(|(canvas, document)| (canvas.id.as_str(), document));
    let switches = workspace
        .as_ref()
        .map(SpawnGateSwitches::from_workspace)
        .unwrap_or_default();
    let grants = load_live_spawn_grants(db, policy, &items, &[]).await?;
    let evaluated_at = utc_now();
    Ok(build_audit_summary_with_policy(
        &items,
        policy,
        &evaluated_at,
        switches,
        &grants,
    ))
}

pub(crate) async fn list_task_board_projects_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardCatalogRequest,
) -> Result<TaskBoardProjectsResponse, CliError> {
    let scope = TaskBoardRepositoryScope::load(db).await?;
    let items = scope.filter_items(db.list_task_board_items(request.status).await?);
    let projects = scope.filter_projects(db.list_task_board_projects().await?);
    Ok(build_project_summaries(&items, &projects))
}

pub(crate) async fn update_task_board_project_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardProjectUpdateRequest,
) -> Result<TaskBoardProjectUpdateResponse, CliError> {
    let display_name = match (request.clear_display_name, request.display_name.as_deref()) {
        // Letting the clear quietly win would report success for a rename the
        // caller never got, and the name it sent would be the thing erased.
        (true, Some(_)) => {
            return Err(CliErrorKind::usage_error(
                "task-board project update cannot both set and clear display_name",
            )
            .into());
        }
        (true, None) => DisplayNameEdit::Clear,
        (false, Some(value)) => DisplayNameEdit::Set(value),
        (false, None) => DisplayNameEdit::Keep,
    };
    let color = match (request.reset_color, request.color) {
        // Same trap as the display name: a silent winner would report success
        // for the edit the caller did not get.
        (true, Some(_)) => {
            return Err(CliErrorKind::usage_error(
                "task-board project update cannot both set and reset color",
            )
            .into());
        }
        (true, None) => ColorEdit::Reset,
        (false, Some(color)) => ColorEdit::Set(color),
        (false, None) => ColorEdit::Keep,
    };
    db.update_task_board_project(
        &request.project_id,
        ProjectEdit {
            slug: request.slug.as_deref(),
            display_name,
            color,
        },
    )
    .await
}

pub(crate) async fn list_task_board_machines_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardCatalogRequest,
) -> Result<TaskBoardMachinesResponse, CliError> {
    let items = scoped_task_board_items_db(db, request.status).await?;
    Ok(build_machine_summaries(&items))
}

pub(crate) async fn task_board_host_local_db(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardHostLocalResponse, CliError> {
    ensure_local_machine(db).await
}

pub(crate) async fn touch_task_board_host_local_db(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardHostLocalResponse, CliError> {
    if let Some((machine, _)) = db.touch_task_board_local_machine().await? {
        return Ok(machine);
    }
    ensure_local_machine(db).await
}

pub(crate) async fn task_board_host_list_db(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardHostListResponse, CliError> {
    db.task_board_machines().await
}

pub(crate) async fn task_board_host_set_project_types_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardHostSetProjectTypesRequest,
) -> Result<TaskBoardHostSetProjectTypesResponse, CliError> {
    let mut machine = ensure_local_machine(db).await?;
    machine.project_types.clone_from(&request.project_types);
    db.set_task_board_local_machine(&machine)
        .await
        .map(|(machine, _)| machine)
}

pub(crate) async fn sync_task_board_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardSyncRequest,
) -> Result<TaskBoardSyncResponse, CliError> {
    if request.dry_run {
        return sync_task_board_db_with_context(db, request, &TaskBoardSyncRunContext::requested())
            .await;
    }
    let config = active_external_sync_config_db(db).await?;
    let items = scoped_task_board_items_db(db, request.status).await?;
    let response = build_sync_summary(&items, &config);
    let db = db.clone();
    let request = request.clone();
    let generation = db.schedule_requested_task_board_sync();
    tokio::spawn(async move {
        let Some(permit) = db.begin_scheduled_task_board_sync(generation).await else {
            return;
        };
        if let Err(error) = sync_task_board_db_with_permit(
            &db,
            &request,
            &TaskBoardSyncRunContext::requested(),
            permit,
        )
        .await
        {
            tracing::warn!(%error, "requested task-board source refresh failed");
        }
    });
    Ok(response)
}

pub(crate) fn cancel_task_board_sync_db(db: &AsyncDaemonDb) -> TaskBoardSyncCancelResponse {
    TaskBoardSyncCancelResponse {
        cancelled: db.cancel_active_task_board_sync(),
    }
}

pub(crate) fn task_board_sync_status_db(db: &AsyncDaemonDb) -> TaskBoardSyncStatusResponse {
    let status = db.task_board_sync_status();
    TaskBoardSyncStatusResponse {
        active: status.active,
        cancellation_requested: status.cancellation_requested,
        cancelled: status.cancelled,
        error: status.error,
        summary: status.summary,
    }
}

pub(crate) async fn sync_task_board_for_orchestrator_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardSyncRequest,
) -> Result<TaskBoardSyncResponse, CliError> {
    sync_task_board_for_orchestrator_with_context_db(
        db,
        request,
        &TaskBoardSyncRunContext::orchestrator(None, None, None),
    )
    .await
}

pub(crate) async fn sync_task_board_for_orchestrator_with_context_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardSyncRequest,
    context: &TaskBoardSyncRunContext,
) -> Result<TaskBoardSyncResponse, CliError> {
    sync_task_board_db_with_context(db, request, context).await
}

async fn sync_task_board_db_with_context(
    db: &AsyncDaemonDb,
    request: &TaskBoardSyncRequest,
    context: &TaskBoardSyncRunContext,
) -> Result<TaskBoardSyncResponse, CliError> {
    let permit = db.begin_task_board_sync().await;
    sync_task_board_db_with_permit(db, request, context, permit).await
}

async fn sync_task_board_db_with_permit(
    db: &AsyncDaemonDb,
    request: &TaskBoardSyncRequest,
    context: &TaskBoardSyncRunContext,
    mut permit: crate::daemon::db::TaskBoardSyncPermit,
) -> Result<TaskBoardSyncResponse, CliError> {
    let context = context.with_cancellation(permit.cancellation());
    let (result, metrics) =
        provider_sync_execution::execute_isolated(db.clone(), request.clone(), context.clone())
            .await;
    context.observe_sync_metrics(&metrics);
    let audit = sync_audit::record_request_result_with_correlation(
        db,
        request,
        context.trigger(),
        context.correlation_id(),
        &result,
        &metrics,
    )
    .await;
    let result = combine_sync_and_audit_results(result, audit);
    permit.record_completion(
        result.as_ref().ok().cloned(),
        result.as_ref().err().map(ToString::to_string),
    );
    result
}

fn combine_sync_and_audit_results(
    sync: Result<TaskBoardSyncResponse, CliError>,
    audit: Result<(), CliError>,
) -> Result<TaskBoardSyncResponse, CliError> {
    match audit {
        Ok(()) => sync,
        Err(audit_error) => combine_audit_failure(sync, audit_error),
    }
}

fn combine_audit_failure(
    sync: Result<TaskBoardSyncResponse, CliError>,
    audit_error: CliError,
) -> Result<TaskBoardSyncResponse, CliError> {
    let Err(sync_error) = sync else {
        return Err(audit_error);
    };
    tracing::error!(
        %sync_error,
        %audit_error,
        "task-board sync and audit persistence both failed"
    );
    Err(CliErrorKind::workflow_io(format!(
        "task-board provider sync failed: {sync_error}; \
task-board sync audit persistence failed: {audit_error}"
    ))
    .into())
}

pub(crate) async fn active_external_sync_config_db(
    db: &AsyncDaemonDb,
) -> Result<ExternalSyncConfig, CliError> {
    let settings = db.task_board_orchestrator_settings().await?;
    Ok(
        super::repository_sync_support::external_sync_config_for_repository(
            None,
            &settings.github_inbox.repositories,
        )
        .with_github_import_labels_override(&settings.github_inbox.label_filter),
    )
}

async fn ensure_local_machine(db: &AsyncDaemonDb) -> Result<Machine, CliError> {
    if let Some(id) = db.task_board_local_machine_id().await? {
        if let Some(machine) = db
            .task_board_machines()
            .await?
            .into_iter()
            .find(|machine| machine.id == id)
        {
            return Ok(machine);
        }
        return db
            .set_task_board_local_machine(&Machine::new(id, default_machine_label()))
            .await
            .map(|(machine, _)| machine);
    }
    let machine = Machine::new(Uuid::new_v4().simple().to_string(), default_machine_label());
    db.set_task_board_local_machine(&machine)
        .await
        .map(|(machine, _)| machine)
}

fn default_machine_label() -> String {
    env::var("HARNESS_MACHINE_LABEL")
        .ok()
        .as_deref()
        .and_then(non_empty)
        .or_else(|| env::var("HOSTNAME").ok().as_deref().and_then(non_empty))
        .unwrap_or_else(|| "local".to_string())
}

fn non_empty(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_owned())
}

#[cfg(test)]
#[path = "task_board_db_tests.rs"]
mod tests;
