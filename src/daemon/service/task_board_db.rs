use std::env;

use async_trait::async_trait;
use uuid::Uuid;

use crate::daemon::db::{AsyncDaemonDb, db_error};
use crate::daemon::protocol::{
    TaskBoardAuditRequest, TaskBoardAuditResponse, TaskBoardCatalogRequest,
    TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest, TaskBoardGetItemRequest,
    TaskBoardHostListResponse, TaskBoardHostLocalResponse, TaskBoardHostSetProjectTypesRequest,
    TaskBoardHostSetProjectTypesResponse, TaskBoardListItemsRequest, TaskBoardListItemsResponse,
    TaskBoardMachinesResponse, TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest,
    TaskBoardPlanRevokeRequest, TaskBoardPlanSubmitRequest, TaskBoardPlanningResponse,
    TaskBoardProjectsResponse, TaskBoardSyncRequest, TaskBoardSyncResponse,
    TaskBoardUpdateItemRequest,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::planning::PlanningTransition;
use crate::task_board::store::{TaskBoardItemPatch, apply_patch};
use crate::task_board::{
    ExternalRef, ExternalSyncConfig, Machine, PlanningState, SpawnGateSwitches, TaskBoardItem,
    TaskBoardStatus, TaskBoardSyncStore, TaskBoardWorkflowState, approve_plan, begin_planning,
    build_audit_summary_with_policy, build_machine_summaries, build_project_summaries,
    configured_sync_clients_without_review_requests, revoke_plan, submit_plan, sync_external_tasks,
};
use crate::workspace::utc_now;

#[cfg(test)]
mod external_ref_tests;
mod reviews_sync;
mod sync_audit;

pub(crate) use reviews_sync::reconcile_shared_review_items_db;
use reviews_sync::shared_review_request_client;
pub(crate) use sync_audit::{
    ReviewsProjectionAuditSummary, record_reviews_projection_result,
    record_targeted_reviews_projection_result,
};

#[async_trait]
impl TaskBoardSyncStore for AsyncDaemonDb {
    async fn list_items(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        self.list_task_board_items(status).await
    }

    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        self.list_task_board_items_including_deleted().await
    }

    async fn create_item(&self, item: TaskBoardItem) -> Result<TaskBoardItem, CliError> {
        self.create_task_board_item(item)
            .await
            .map(|mutation| mutation.item)
    }

    async fn update_item(
        &self,
        expected_item: &TaskBoardItem,
        patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        let item_id = expected_item.id.clone();
        self.update_task_board_item(&item_id, |item| {
            if item != expected_item {
                return Err(CliErrorKind::concurrent_modification(format!(
                    "task-board item '{item_id}' changed during external sync"
                ))
                .into());
            }
            apply_patch(item, patch);
            Ok(true)
        })
        .await?
        .map(|mutation| mutation.item)
        .ok_or_else(|| db_error("Task Board sync update produced no mutation"))
    }
}

pub(crate) async fn create_task_board_item_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardCreateItemRequest,
) -> Result<TaskBoardItem, CliError> {
    let mut item = TaskBoardItem::new(
        request
            .id
            .clone()
            .unwrap_or_else(|| format!("task-{}", Uuid::new_v4().simple())),
        request.title.clone(),
        request.body.clone(),
        utc_now(),
    );
    item.priority = request.priority;
    item.agent_mode = request.agent_mode;
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
    Ok(db.create_task_board_item(item).await?.item)
}

pub(crate) async fn list_task_board_items_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardListItemsRequest,
) -> Result<TaskBoardListItemsResponse, CliError> {
    db.list_task_board_items(request.status)
        .await
        .map(|items| TaskBoardListItemsResponse { items })
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
    super::task_board_completion::validate_linked_task_completion(db, id, request.status).await?;
    let mutation = db
        .update_task_board_item(id, |item| {
            apply_update_request(item, request);
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
    Ok(build_audit_summary_with_policy(&items, policy, switches))
}

pub(crate) async fn list_task_board_projects_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardCatalogRequest,
) -> Result<TaskBoardProjectsResponse, CliError> {
    let items = db.list_task_board_items(request.status).await?;
    Ok(build_project_summaries(&items))
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
    sync_task_board_db_with_trigger(
        db,
        request,
        sync_audit::TaskBoardSyncAuditTrigger::Requested,
    )
    .await
}

pub(crate) async fn sync_task_board_for_orchestrator_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardSyncRequest,
) -> Result<TaskBoardSyncResponse, CliError> {
    sync_task_board_db_with_trigger(
        db,
        request,
        sync_audit::TaskBoardSyncAuditTrigger::Orchestrator,
    )
    .await
}

async fn sync_task_board_db_with_trigger(
    db: &AsyncDaemonDb,
    request: &TaskBoardSyncRequest,
    trigger: sync_audit::TaskBoardSyncAuditTrigger,
) -> Result<TaskBoardSyncResponse, CliError> {
    let result = sync_task_board_db_inner(db, request).await;
    sync_audit::record_request_result(db, request, trigger, &result).await;
    result
}

async fn sync_task_board_db_inner(
    db: &AsyncDaemonDb,
    request: &TaskBoardSyncRequest,
) -> Result<TaskBoardSyncResponse, CliError> {
    let config = active_external_sync_config_db(db).await?;
    let mut clients = configured_sync_clients_without_review_requests(&config, request.provider)?;
    if let Some(shared_reviews) = shared_review_request_client(db, request).await? {
        clients.push(Box::new(shared_reviews));
    }
    super::task_board::log_sync_request(request, &config, clients.len());
    super::task_board::ensure_sync_request_can_run(request, &config, &clients)?;
    let operations =
        sync_external_tasks(db, super::task_board::sync_options(request), &clients).await?;
    let items = db.list_task_board_items(request.status).await?;
    let summary = super::task_board::build_sync_response_from_items(&items, &config, operations);
    super::task_board::log_sync_completion(&summary);
    Ok(summary)
}

pub(crate) async fn active_external_sync_config_db(
    db: &AsyncDaemonDb,
) -> Result<ExternalSyncConfig, CliError> {
    let settings = db.task_board_orchestrator_settings().await?;
    let project = &settings.github_project;
    let repository = (!project.owner.trim().is_empty() && !project.repo.trim().is_empty())
        .then(|| project.repository_slug());
    Ok(
        super::task_board_runtime::external_sync_config_for_repository(
            repository.as_deref(),
            &settings.github_inbox.repositories,
        )
        .with_github_import_labels_override(&settings.github_inbox.label_filter)
        .with_todoist_import_project_ids_override(&settings.todoist_inbox.project_filter),
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

fn apply_update_request(item: &mut TaskBoardItem, request: &TaskBoardUpdateItemRequest) {
    assign_if_some(&mut item.title, request.title.as_ref());
    assign_if_some(&mut item.body, request.body.as_ref());
    assign_copy_if_some(&mut item.status, request.status);
    assign_copy_if_some(&mut item.priority, request.priority);
    assign_copy_if_some(&mut item.agent_mode, request.agent_mode);
    assign_if_some(&mut item.tags, request.tags.as_ref());
    assign_if_some(
        &mut item.target_project_types,
        request.target_project_types.as_ref(),
    );
    if let Some(replacements) = request.external_refs.as_deref() {
        item.external_refs = replacement_external_refs(&item.external_refs, replacements);
    }
    apply_optional_string(
        &mut item.project_id,
        request.project_id.as_ref(),
        request.clear_identity.clear_project_id,
    );
    apply_optional_string(
        &mut item.session_id,
        request.session_id.as_ref(),
        request.clear_identity.clear_session_id,
    );
    apply_optional_string(
        &mut item.work_item_id,
        request.work_item_id.as_ref(),
        request.clear_identity.clear_work_item_id,
    );
    apply_update_state(item, request);
}

fn replacement_external_refs(
    current: &[ExternalRef],
    replacements: &[ExternalRef],
) -> Vec<ExternalRef> {
    replacements
        .iter()
        .map(|replacement| ExternalRef {
            provider: replacement.provider,
            external_id: replacement.external_id.clone(),
            url: replacement.url.clone(),
            sync_state: current
                .iter()
                .find(|candidate| {
                    candidate.provider == replacement.provider
                        && candidate.external_id == replacement.external_id
                })
                .and_then(|candidate| candidate.sync_state.clone()),
        })
        .collect()
}

fn apply_update_state(item: &mut TaskBoardItem, request: &TaskBoardUpdateItemRequest) {
    if request.clear_state.clear_planning {
        item.planning = PlanningState::default();
    } else if let Some(planning) = &request.planning {
        if planning.summary.is_some() {
            item.planning.clone_from(planning);
        } else if planning.approved_by.is_some() {
            item.planning.approved_by.clone_from(&planning.approved_by);
            item.planning.approved_at.clone_from(&planning.approved_at);
        }
    }
    if request.clear_state.clear_workflow {
        item.workflow = TaskBoardWorkflowState::default();
    } else if let Some(workflow) = &request.workflow {
        item.workflow.clone_from(workflow);
    }
}

fn assign_if_some<T: Clone>(target: &mut T, value: Option<&T>) {
    if let Some(value) = value {
        target.clone_from(value);
    }
}

fn assign_copy_if_some<T: Copy>(target: &mut T, value: Option<T>) {
    if let Some(value) = value {
        *target = value;
    }
}

fn apply_optional_string(target: &mut Option<String>, value: Option<&String>, clear: bool) {
    if clear {
        *target = None;
    } else if let Some(value) = value {
        *target = Some(value.clone());
    }
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
mod tests {
    use tempfile::tempdir;

    use super::*;

    #[tokio::test]
    async fn external_sync_update_rejects_a_concurrent_local_edit() {
        let dir = tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
            .await
            .expect("open database");
        let created = db
            .create_task_board_item(TaskBoardItem::new(
                "task-concurrent-sync".into(),
                "Original title".into(),
                "Original body".into(),
                "2026-07-11T12:00:00Z".into(),
            ))
            .await
            .expect("create item")
            .item;
        db.update_task_board_item(&created.id, |item| {
            item.body = "Concurrent local edit".into();
            Ok(true)
        })
        .await
        .expect("local edit");

        let error = <AsyncDaemonDb as TaskBoardSyncStore>::update_item(
            &db,
            &created,
            TaskBoardItemPatch {
                title: Some("Remote title".into()),
                ..TaskBoardItemPatch::default()
            },
        )
        .await
        .expect_err("stale sync snapshot must be rejected");
        let current = db.task_board_item(&created.id).await.expect("current item");

        assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
        assert_eq!(current.title, "Original title");
        assert_eq!(current.body, "Concurrent local edit");
    }
}
