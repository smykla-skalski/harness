use std::env;

use uuid::Uuid;

use crate::daemon::db::{AsyncDaemonDb, ColorEdit, DisplayNameEdit, ProjectEdit};
use crate::daemon::protocol::{
    TaskBoardAuditRequest, TaskBoardAuditResponse, TaskBoardCatalogRequest,
    TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest, TaskBoardGetItemRequest,
    TaskBoardHostListResponse, TaskBoardHostLocalResponse, TaskBoardHostSetProjectTypesRequest,
    TaskBoardHostSetProjectTypesResponse, TaskBoardMachinesResponse, TaskBoardPlanApproveRequest,
    TaskBoardPlanBeginRequest, TaskBoardPlanRevokeRequest, TaskBoardPlanSubmitRequest,
    TaskBoardPlanningResponse, TaskBoardProjectUpdateRequest, TaskBoardProjectUpdateResponse,
    TaskBoardProjectsResponse, TaskBoardSyncRequest,
    TaskBoardSyncResponse, TaskBoardUpdateItemRequest,
};
use harness_kernel::errors::{CliError, CliErrorKind};
use crate::task_board::planning::PlanningTransition;
use crate::task_board::{
    ExternalSyncConfig, Machine, SpawnGateSwitches, TaskBoardItem, approve_plan, begin_planning,
    build_audit_summary_with_policy, build_machine_summaries, build_project_summaries, revoke_plan,
    submit_plan,
};
use crate::workspace::utc_now;

use super::task_board::load_live_spawn_grants;

pub(crate) use crate::task_board::external::{
    TaskBoardSyncCoordinatorFence, TaskBoardSyncCoordinatorFenceDecision,
};

#[cfg(test)]
mod external_ref_tests;
mod list_items;
mod positions;
mod provider_sync_context_store;
mod provider_sync_exclusion;
mod provider_sync_execution;
mod provider_sync_store;
mod request_validation;
mod reviews_sync;
mod sync_audit;
mod sync_run_context;
mod triage_reads;
mod triage_rules_reads;
mod update_request;

use request_validation::{validate_create_title, validate_estimate, validate_update_estimates};
use update_request::{apply_update_request, replacement_external_refs};
pub(crate) use list_items::{TaskBoardListSource, read_task_board_items_db};
pub(crate) use positions::{
    get_task_board_item_position_snapshot_db, reset_task_board_item_position_db,
    set_task_board_item_position_db,
};
pub(crate) use reviews_sync::reconcile_shared_review_items_db;
use reviews_sync::shared_review_request_clients;
use sync_audit::SyncExecutionMetrics;
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
    let mutation = if request.status.is_some() {
        db.create_task_board_item_at_requested_status(item).await?
    } else {
        db.create_task_board_item_with_triage(item).await?
    };
    Ok(mutation.item)
}

pub(crate) async fn get_task_board_item_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardGetItemRequest,
) -> Result<TaskBoardItem, CliError> {
    db.task_board_item(&request.id).await
}

pub(crate) async fn update_task_board_item_db(
    db: &AsyncDaemonDb,
    id: &str,
    request: &TaskBoardUpdateItemRequest,
) -> Result<TaskBoardItem, CliError> {
    validate_update_estimates(request)?;
    super::task_board_completion::validate_linked_task_completion(db, id, request.status).await?;
    let mutation = db
        .update_task_board_item_with_triage(id, |item| {
            apply_update_request(item, request)?;
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
    Ok(db.delete_task_board_item(&request.id).await?.item)
}

pub(crate) async fn begin_task_board_planning_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardPlanBeginRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    apply_planning_transition_db(db, &request.id, begin_planning).await
}

pub(crate) async fn submit_task_board_plan_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardPlanSubmitRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    apply_planning_transition_db(db, &request.id, |item| submit_plan(item, &request.summary)).await
}

pub(crate) async fn approve_task_board_plan_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardPlanApproveRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    let approved_at = request.approved_at.clone().unwrap_or_else(utc_now);
    apply_planning_transition_db(db, &request.id, |item| {
        approve_plan(item, &request.approved_by, &approved_at)
    })
    .await
}

pub(crate) async fn revoke_task_board_plan_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardPlanRevokeRequest,
) -> Result<TaskBoardPlanningResponse, CliError> {
    apply_planning_transition_db(db, &request.id, |item| {
        revoke_plan(item, request.actor.as_deref())
    })
    .await
}

pub(crate) async fn audit_task_board_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardAuditRequest,
) -> Result<TaskBoardAuditResponse, CliError> {
    let items = db.list_task_board_items(request.status).await?;
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
    let items = db.list_task_board_items(request.status).await?;
    let projects = db.list_task_board_projects().await?;
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
    let items = db.list_task_board_items(request.status).await?;
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
    sync_task_board_db_with_context(db, request, &TaskBoardSyncRunContext::requested()).await
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
    let mut metrics = SyncExecutionMetrics::default();
    let result = provider_sync_execution::execute(db, request, context, &mut metrics).await;
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
    combine_sync_and_audit_results(result, audit)
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
        super::task_board_runtime::external_sync_config_for_repository(
            None,
            &settings.github_inbox.repositories,
        )
        .with_github_import_labels_override(&settings.github_inbox.label_filter),
    )
}

async fn apply_planning_transition_db(
    db: &AsyncDaemonDb,
    id: &str,
    transition_for: impl FnOnce(&TaskBoardItem) -> PlanningTransition,
) -> Result<TaskBoardPlanningResponse, CliError> {
    let mut transition = None;
    let mutation = db
        .update_task_board_item(id, |item| {
            let next = transition_for(item);
            item.status = next.to_status;
            item.planning.clone_from(&next.planning);
            transition = Some(next);
            Ok(true)
        })
        .await?
        .expect("task-board planning transition always mutates");
    Ok(TaskBoardPlanningResponse {
        transition: transition.expect("task-board transition was captured"),
        item: mutation.item,
    })
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
