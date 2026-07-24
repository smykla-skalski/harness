//! ACP managed-agent mutations: prompt, logout, and permission-batch
//! resolution. They share the session lock and blocking-worker helpers in
//! [`super::mutations`].

use std::time::Instant;

use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;

use crate::daemon::agent_acp::AcpPermissionDecision;
use crate::daemon::protocol::{ManagedAgentSnapshot, http_paths};
#[cfg(feature = "openapi")]
use crate::daemon::protocol::ManagedAgentSnapshotSchema;
use crate::errors::CliError;

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
#[cfg(feature = "openapi")]
use super::super::openapi::{DaemonErrorBody, OkResponse};
use super::super::response::{extract_request_id, timed_json};
use super::mutations::with_managed_agent_lock;
use super::{ensure_acp_agent, ensure_acp_enabled, run_acp_agent_blocking};

fn acp_session_id(state: &DaemonHttpState, agent_id: &str) -> Result<String, CliError> {
    ensure_acp_enabled()?;
    ensure_acp_agent(state, agent_id)?;
    state.acp_agent_manager.get(agent_id).map(|s| s.session_id)
}

#[derive(serde::Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub(super) struct AcpPromptRequestBody {
    pub prompt: String,
}

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/managed-agents/{managed_agent_id}/prompt",
    tag = "managed-agents",
    params(
        ("managed_agent_id" = String, Path, description = "Managed agent identifier"),
    ),
    request_body = AcpPromptRequestBody,
    responses(
        (status = 200, description = "ACP agent snapshot after sending the prompt", body = ManagedAgentSnapshotSchema),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(super) async fn post_acp_agent_prompt(
    Path(agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AcpPromptRequestBody>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match acp_session_id(&state, &agent_id) {
        Ok(session_id) => {
            let prompt = request.prompt;
            let prompt_agent_id = agent_id.clone();
            with_managed_agent_lock(&state, &session_id, &agent_id, || {
                run_acp_agent_blocking(&state, "prompt", move |manager| {
                    manager
                        .send_prompt(&prompt_agent_id, &prompt)
                        .map(ManagedAgentSnapshot::Acp)
                })
            })
            .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_ACP_PROMPT,
        &request_id,
        start,
        result,
    )
}

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/managed-agents/{managed_agent_id}/logout",
    tag = "managed-agents",
    params(
        ("managed_agent_id" = String, Path, description = "Managed agent identifier"),
    ),
    responses(
        (status = 200, description = "ACP agent logged out", body = OkResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(super) async fn post_acp_agent_logout(
    Path(agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match acp_session_id(&state, &agent_id) {
        Ok(session_id) => {
            let logout_agent_id = agent_id.clone();
            with_managed_agent_lock(&state, &session_id, &agent_id, || {
                run_acp_agent_blocking(&state, "logout", move |manager| {
                    manager
                        .logout(&logout_agent_id)
                        .map(|()| serde_json::json!({ "ok": true }))
                })
            })
            .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_ACP_LOGOUT,
        &request_id,
        start,
        result,
    )
}

#[cfg_attr(feature = "openapi", utoipa::path(
    post,
    path = "/v1/managed-agents/{managed_agent_id}/permission-batches/{batch_id}",
    tag = "managed-agents",
    params(
        ("managed_agent_id" = String, Path, description = "Managed agent identifier"),
        ("batch_id" = String, Path, description = "Pending permission batch identifier"),
    ),
    request_body = AcpPermissionDecision,
    responses(
        (status = 200, description = "ACP agent snapshot after resolving the permission batch", body = ManagedAgentSnapshotSchema),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
))]
pub(super) async fn post_acp_permission(
    Path((agent_id, batch_id)): Path<(String, String)>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AcpPermissionDecision>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = match acp_session_id(&state, &agent_id) {
        Ok(session_id) => {
            let decision_agent_id = agent_id.clone();
            let decision_batch_id = batch_id.clone();
            with_managed_agent_lock(&state, &session_id, &agent_id, || {
                run_acp_agent_blocking(&state, "permission", move |manager| {
                    manager
                        .resolve_permission_batch(&decision_agent_id, &decision_batch_id, &request)
                        .map(ManagedAgentSnapshot::Acp)
                })
            })
            .await
        }
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_ACP_PERMISSION,
        &request_id,
        start,
        result,
    )
}
