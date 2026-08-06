use std::time::Instant;

use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use harness_kernel::errors::CliError;
use harness_protocol::session::ManagedAgentKind;
use serde::Deserialize;

use crate::daemon::protocol::{ManagedAgentSnapshot, ManagedAgentSnapshotSchema, http_paths};

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
use super::super::openapi::DaemonErrorBody;
use super::super::response::{extract_request_id, timed_json};
use super::mutations::with_managed_agent_lock;
use super::{
    locate_managed_agent_kind, record_runtime_stop_result, run_acp_agent_blocking,
    run_codex_agent_blocking, run_terminal_agent_blocking,
};

#[derive(Debug, Default, Deserialize)]
pub(super) struct ManagedAgentStopQuery {
    managed_agent_kind: Option<ManagedAgentKind>,
}

#[utoipa::path(
    post,
    path = "/v1/managed-agents/{managed_agent_id}/stop",
    tag = "managed-agents",
    description = "Stop the single managed runtime owning an identifier and reject ambiguous cross-family identifiers",
    params(
        ("managed_agent_id" = String, Path, description = "Managed agent identifier"),
        ("managed_agent_kind" = Option<ManagedAgentKind>, Query, description = "Runtime family that qualifies identifiers shared by multiple managers"),
    ),
    responses(
        (status = 200, description = "Managed agent snapshot after stop", body = ManagedAgentSnapshotSchema),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_managed_agent_stop(
    Path(managed_agent_id): Path<String>,
    Query(query): Query<ManagedAgentStopQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let kind = match query.managed_agent_kind {
        Some(kind) => kind,
        None => match locate_managed_agent_kind(&state, &managed_agent_id).await {
            Ok(kind) => kind,
            Err(error) => {
                return timed_json(
                    "POST",
                    http_paths::MANAGED_AGENT_STOP,
                    &request_id,
                    start,
                    Err::<ManagedAgentSnapshot, _>(error),
                );
            }
        },
    };
    let attempt = stop_managed_agent(&state, kind, &managed_agent_id).await;
    let result = record_runtime_stop_result(&state, kind, &managed_agent_id, attempt).await;
    timed_json(
        "POST",
        http_paths::MANAGED_AGENT_STOP,
        &request_id,
        start,
        result,
    )
}

pub(crate) async fn stop_managed_agent(
    state: &DaemonHttpState,
    kind: ManagedAgentKind,
    managed_agent_id: &str,
) -> super::ManagedAgentStopAttempt {
    let daemon_id = if let Some(db) = state.async_db.get() {
        match crate::daemon::service::prepare_agent_workspace_operation_async(
            db,
            kind,
            managed_agent_id,
        )
        .await
        {
            Ok(daemon_id) => Some(daemon_id),
            Err(error) => return super::ManagedAgentStopAttempt::failed(error),
        }
    } else {
        None
    };
    let result = match kind {
        ManagedAgentKind::Codex => stop_codex(state, managed_agent_id).await,
        ManagedAgentKind::Acp => stop_acp(state, managed_agent_id).await,
        ManagedAgentKind::Tui => stop_terminal(state, managed_agent_id).await,
    };
    super::ManagedAgentStopAttempt { daemon_id, result }
}

async fn stop_codex(
    state: &DaemonHttpState,
    managed_agent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    let session_id = state
        .codex_controller
        .session_id_for_run(managed_agent_id)?;
    let agent_id = managed_agent_id.to_string();
    with_managed_agent_lock(state, &session_id, managed_agent_id, || {
        run_codex_agent_blocking(state, "stop", move |controller| {
            controller.stop(&agent_id).map(ManagedAgentSnapshot::Codex)
        })
    })
    .await
}

async fn stop_acp(
    state: &DaemonHttpState,
    managed_agent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    let session_id = state.acp_agent_manager.get(managed_agent_id)?.session_id;
    let agent_id = managed_agent_id.to_string();
    with_managed_agent_lock(state, &session_id, managed_agent_id, || {
        run_acp_agent_blocking(state, "stop", move |manager| {
            manager.stop(&agent_id).map(ManagedAgentSnapshot::Acp)
        })
    })
    .await
}

async fn stop_terminal(
    state: &DaemonHttpState,
    managed_agent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    let lookup_id = managed_agent_id.to_string();
    let session_id = run_terminal_agent_blocking(state, "stop lookup", move |manager| {
        manager.get(&lookup_id).map(|snapshot| snapshot.session_id)
    })
    .await?;
    let agent_id = managed_agent_id.to_string();
    with_managed_agent_lock(state, &session_id, managed_agent_id, || {
        run_terminal_agent_blocking(state, "stop", move |manager| manager.stop(&agent_id))
    })
    .await
    .map(ManagedAgentSnapshot::Terminal)
}
