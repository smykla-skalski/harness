use std::time::Instant;

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use harness_protocol::daemon::activity::{
    AgentWorkspaceActivityWindowResponse, AgentWorkspaceMemberActivityResponse,
    AgentWorkspaceSignalAckRequest, AgentWorkspaceSignalCancelRequest, AgentWorkspaceSignalRecord,
    AgentWorkspaceSignalSendRequest,
};
use harness_protocol::timeline::{TimelineCursor, TimelineWindowRequest};
use utoipa_axum::router::OpenApiRouter;
use utoipa_axum::routes;

use super::auth::{authorize_control_request, require_auth};
use super::openapi::DaemonErrorBody;
use super::response::{extract_request_id, timed_json};
use super::{DaemonHttpState, require_async_db};
use crate::daemon::protocol::http_paths;
use crate::daemon::service;

pub(super) fn routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(get_workspace_activity))
        .routes(routes!(get_member_activity))
        .routes(routes!(post_signal))
        .routes(routes!(post_signal_ack))
        .routes(routes!(post_signal_cancel))
}

#[derive(utoipa::IntoParams)]
#[into_params(parameter_in = Query)]
#[derive(Debug, Default, serde::Deserialize)]
pub(super) struct ActivityWindowQuery {
    #[serde(default)]
    scope: Option<String>,
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    known_revision: Option<i64>,
    #[serde(default)]
    before_recorded_at: Option<String>,
    #[serde(default)]
    before_entry_id: Option<String>,
    #[serde(default)]
    after_recorded_at: Option<String>,
    #[serde(default)]
    after_entry_id: Option<String>,
}

impl ActivityWindowQuery {
    pub(super) fn into_request(self) -> TimelineWindowRequest {
        TimelineWindowRequest {
            scope: self.scope,
            limit: self.limit,
            known_revision: self.known_revision,
            before: cursor(self.before_recorded_at, self.before_entry_id),
            after: cursor(self.after_recorded_at, self.after_entry_id),
        }
    }
}

#[utoipa::path(
    get,
    path = "/v1/agent-workspaces/{workspace_id}/activity",
    tag = "agents",
    description = "Return the workspace-owned durable activity timeline",
    params(
        ("workspace_id" = String, Path, description = "Durable workspace identifier"),
        ActivityWindowQuery,
    ),
    responses(
        (status = 200, description = "Durable workspace activity", body = AgentWorkspaceActivityWindowResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn get_workspace_activity(
    headers: HeaderMap,
    Path(workspace_id): Path<String>,
    Query(query): Query<ActivityWindowQuery>,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match require_async_db(&state, "agent workspace activity") {
        Ok(db) => {
            service::get_agent_workspace_activity_async(db, &workspace_id, &query.into_request())
                .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "GET",
        http_paths::AGENT_WORKSPACE_ACTIVITY,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    get,
    path = "/v1/agent-workspaces/{workspace_id}/members/{member_id}/activity",
    tag = "agents",
    description = "Return one durable member's activity, transcript, and signals",
    params(
        ("workspace_id" = String, Path, description = "Durable workspace identifier"),
        ("member_id" = String, Path, description = "Workspace-owned member identifier"),
    ),
    responses(
        (status = 200, description = "Durable member activity", body = AgentWorkspaceMemberActivityResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn get_member_activity(
    headers: HeaderMap,
    Path((workspace_id, member_id)): Path<(String, String)>,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match require_async_db(&state, "agent workspace member activity") {
        Ok(db) => {
            service::get_agent_workspace_member_activity_async(db, &workspace_id, &member_id).await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "GET",
        http_paths::AGENT_WORKSPACE_MEMBER_ACTIVITY,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/agent-workspaces/{workspace_id}/members/{member_id}/signals",
    tag = "agents",
    description = "Persist and deliver a signal directly to a durable managed agent",
    params(
        ("workspace_id" = String, Path, description = "Durable workspace identifier"),
        ("member_id" = String, Path, description = "Workspace-owned member identifier"),
    ),
    request_body = AgentWorkspaceSignalSendRequest,
    responses(
        (status = 200, description = "Durable signal record", body = AgentWorkspaceSignalRecord),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn post_signal(
    headers: HeaderMap,
    Path((workspace_id, member_id)): Path<(String, String)>,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<AgentWorkspaceSignalSendRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = match require_async_db(&state, "agent workspace signal") {
        Ok(db) => {
            service::send_agent_workspace_signal_async(
                db,
                &workspace_id,
                &member_id,
                &request,
                state.wake_dispatch(),
            )
            .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::AGENT_WORKSPACE_SIGNAL_SEND,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/agent-workspaces/{workspace_id}/members/{member_id}/signals/{signal_id}/ack",
    tag = "agents",
    description = "Acknowledge a durable managed-agent signal",
    params(
        ("workspace_id" = String, Path, description = "Durable workspace identifier"),
        ("member_id" = String, Path, description = "Workspace-owned member identifier"),
        ("signal_id" = String, Path, description = "Signal identifier"),
    ),
    request_body = AgentWorkspaceSignalAckRequest,
    responses(
        (status = 200, description = "Acknowledged durable signal", body = AgentWorkspaceSignalRecord),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn post_signal_ack(
    headers: HeaderMap,
    Path((workspace_id, member_id, signal_id)): Path<(String, String, String)>,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AgentWorkspaceSignalAckRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match require_async_db(&state, "agent workspace signal acknowledgment") {
        Ok(db) => {
            service::acknowledge_agent_workspace_signal_async(
                db,
                &workspace_id,
                &member_id,
                &signal_id,
                &request,
            )
            .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::AGENT_WORKSPACE_SIGNAL_ACK,
        &request_id,
        start,
        result,
    )
}

#[utoipa::path(
    post,
    path = "/v1/agent-workspaces/{workspace_id}/members/{member_id}/signals/{signal_id}/cancel",
    tag = "agents",
    description = "Cancel a pending durable managed-agent signal",
    params(
        ("workspace_id" = String, Path, description = "Durable workspace identifier"),
        ("member_id" = String, Path, description = "Workspace-owned member identifier"),
        ("signal_id" = String, Path, description = "Signal identifier"),
    ),
    request_body = AgentWorkspaceSignalCancelRequest,
    responses(
        (status = 200, description = "Cancelled durable signal", body = AgentWorkspaceSignalRecord),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
async fn post_signal_cancel(
    headers: HeaderMap,
    Path((workspace_id, member_id, signal_id)): Path<(String, String, String)>,
    State(state): State<DaemonHttpState>,
    Json(mut request): Json<AgentWorkspaceSignalCancelRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = authorize_control_request(&headers, &state, &mut request) {
        return *response;
    }
    let result = match require_async_db(&state, "agent workspace signal cancellation") {
        Ok(db) => {
            service::cancel_agent_workspace_signal_async(
                db,
                &workspace_id,
                &member_id,
                &signal_id,
                &request,
            )
            .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::AGENT_WORKSPACE_SIGNAL_CANCEL,
        &request_id,
        start,
        result,
    )
}

fn cursor(recorded_at: Option<String>, entry_id: Option<String>) -> Option<TimelineCursor> {
    match (recorded_at, entry_id) {
        (Some(recorded_at), Some(entry_id)) => Some(TimelineCursor {
            recorded_at,
            entry_id,
        }),
        _ => None,
    }
}
