//! HTTP handlers for the in-daemon `OpenRouter` agent backend.
//!
//! Routes:
//! - `POST /v1/sessions/{session_id}/managed-agents/openrouter` — create a
//!   session and (optionally) submit the first prompt in one shot.
//! - `GET  /v1/sessions/{session_id}/managed-agents/openrouter` — list every
//!   `OpenRouter` session attached to a harness session.
//! - `GET  /v1/managed-agents/{managed_agent_id}/openrouter` — snapshot.
//! - `POST /v1/managed-agents/{managed_agent_id}/openrouter/prompt` — send
//!   another user turn to an existing session.
//! - `POST /v1/managed-agents/{managed_agent_id}/openrouter/cancel` — abort
//!   the in-flight turn.

use std::time::Instant;

use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;

use crate::daemon::openrouter_agent::OpenRouterStartRequest;
use crate::daemon::protocol::http_paths;
use crate::errors::CliError;

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
use super::super::response::{extract_request_id, timed_json};

pub(super) async fn post_openrouter_start(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<OpenRouterStartRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = state.openrouter_agent_manager.start(&session_id, request);
    timed_json(
        "POST",
        http_paths::SESSION_MANAGED_AGENTS_OPENROUTER,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn get_openrouter_runs(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result: Result<_, CliError> =
        Ok(state.openrouter_agent_manager.list_for_session(&session_id));
    timed_json(
        "GET",
        http_paths::SESSION_MANAGED_AGENTS_OPENROUTER,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn get_openrouter_run(
    Path(managed_agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = state.openrouter_agent_manager.get(&managed_agent_id);
    timed_json(
        "GET",
        http_paths::MANAGED_AGENT_OPENROUTER,
        &request_id,
        start,
        result,
    )
}

#[derive(Debug, Clone, Default, Deserialize)]
pub(super) struct OpenRouterPromptRequest {
    pub prompt: String,
}

pub(super) async fn post_openrouter_prompt(
    Path(managed_agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<OpenRouterPromptRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = state
        .openrouter_agent_manager
        .prompt(&managed_agent_id, request.prompt);
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_OPENROUTER_PROMPT,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn post_openrouter_cancel(
    Path(managed_agent_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = state.openrouter_agent_manager.cancel(&managed_agent_id);
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_OPENROUTER_CANCEL,
        &request_id,
        start,
        result,
    )
}

pub(super) async fn get_openrouter_models(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result = state.openrouter_agent_manager.list_models().await;
    timed_json(
        "GET",
        http_paths::MANAGED_AGENTS_OPENROUTER_MODELS,
        &request_id,
        start,
        result,
    )
}
