use axum::extract::rejection::QueryRejection;
use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;

use crate::daemon::protocol::{
    TASK_BOARD_TRIAGE_HISTORY_INVALID_PARAMS, TaskBoardTriageHistoryRequest, http_paths,
};
use crate::daemon::remote_task_board::{
    project_task_board_triage_current, project_task_board_triage_history,
};
use crate::errors::{CliError, CliErrorKind};

use super::super::DaemonHttpState;
use super::super::response::timed_json;
use super::super::task_board_route_executor;
use super::items::authenticated_task_board_read;

#[derive(Debug, Clone, Default, Deserialize)]
pub(super) struct TaskBoardTriageHistoryQuery {
    pub before_generation: Option<u64>,
    pub limit: Option<u32>,
}

pub(super) async fn get_task_board_item_triage(
    Path(item_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id, viewer) = match authenticated_task_board_read(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let result = task_board_route_executor::get_item_triage_current(&state, &item_id)
        .await
        .map(|response| project_task_board_triage_current(response, viewer));
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ITEM_TRIAGE,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn get_task_board_item_triage_history(
    Path(item_id): Path<String>,
    query: Result<Query<TaskBoardTriageHistoryQuery>, QueryRejection>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let (start, request_id, viewer) = match authenticated_task_board_read(&headers, &state) {
        Ok(parts) => parts,
        Err(response) => return *response,
    };
    let result = match query {
        Ok(Query(query)) => {
            let request = TaskBoardTriageHistoryRequest {
                id: item_id.clone(),
                before_generation: query.before_generation,
                limit: query.limit,
            };
            match request.validated_page() {
                Some((before_generation, limit)) => {
                    task_board_route_executor::get_item_triage_history(
                        &state,
                        &item_id,
                        before_generation,
                        limit,
                    )
                    .await
                }
                None => Err(invalid_triage_history_params()),
            }
        }
        Err(_) => Err(invalid_triage_history_params()),
    }
    .map(|response| project_task_board_triage_history(response, viewer));
    timed_json(
        "GET",
        http_paths::TASK_BOARD_ITEM_TRIAGE_HISTORY,
        &request_id,
        start,
        result,
    )
}

fn invalid_triage_history_params() -> CliError {
    CliErrorKind::workflow_io(TASK_BOARD_TRIAGE_HISTORY_INVALID_PARAMS).into()
}
