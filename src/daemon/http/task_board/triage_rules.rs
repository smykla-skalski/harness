use axum::Json;
use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;

use crate::daemon::protocol::{
    TaskBoardActivateTriageRulesRequest, TaskBoardPreviewTriageRulesRequest,
    TaskBoardSaveTriageRulesDraftRequest, http_paths,
};

use super::super::DaemonHttpState;
use super::super::response::timed_json;
use super::super::task_board_route_executor;
use super::items::{authenticated_task_board_read, authorized_control_request_parts};

#[derive(Debug, Clone, Default, Deserialize)]
pub(super) struct TaskBoardTriageRulesListQuery {
    pub limit: Option<u32>,
}

pub(super) async fn get_task_board_triage_rules_draft(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id, _viewer) = match authenticated_task_board_read(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_TRIAGE_RULES_DRAFT,
        &request_id,
        start,
        task_board_route_executor::get_triage_rules_draft(&state).await,
    )
}

pub(super) async fn put_task_board_triage_rules_draft(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskBoardSaveTriageRulesDraftRequest>,
) -> Response {
    let (start, request_id) = match authorized_control_request_parts(&headers, &state, &mut request)
    {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "PUT",
        http_paths::TASK_BOARD_TRIAGE_RULES_DRAFT,
        &request_id,
        start,
        task_board_route_executor::save_triage_rules_draft(&state, &request).await,
    )
}

pub(super) async fn post_task_board_triage_rules_preview(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardPreviewTriageRulesRequest>,
) -> Response {
    let (start, request_id, _viewer) = match authenticated_task_board_read(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_TRIAGE_RULES_PREVIEW,
        &request_id,
        start,
        task_board_route_executor::preview_triage_rules(&state, &request).await,
    )
}

pub(super) async fn post_task_board_triage_rules_activate(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<TaskBoardActivateTriageRulesRequest>,
) -> Response {
    let (start, request_id) = match authorized_control_request_parts(&headers, &state, &mut request)
    {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_TRIAGE_RULES_ACTIVATE,
        &request_id,
        start,
        task_board_route_executor::activate_triage_rules(&state, &request).await,
    )
}

pub(super) async fn get_task_board_triage_rules_revisions(
    Query(query): Query<TaskBoardTriageRulesListQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id, _viewer) = match authenticated_task_board_read(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_TRIAGE_RULES_REVISIONS,
        &request_id,
        start,
        task_board_route_executor::get_triage_rules_revisions(&state, query.limit).await,
    )
}

pub(super) async fn get_task_board_triage_rules_audit(
    Query(query): Query<TaskBoardTriageRulesListQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id, _viewer) = match authenticated_task_board_read(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    timed_json(
        "GET",
        http_paths::TASK_BOARD_TRIAGE_RULES_AUDIT,
        &request_id,
        start,
        task_board_route_executor::get_triage_rules_audit(&state, query.limit).await,
    )
}
