use axum::routing::get;
use tokio::task::spawn_blocking;
use utoipa_axum::router::OpenApiRouter;
use utoipa_axum::routes;

use crate::daemon::agent_acp::AcpAgentManagerHandle;
use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::protocol::{AcpTranscriptResponse, http_paths};
use crate::daemon::service::session_acp_transcript_async;
use crate::feature_flags::acp_enabled_from_env;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::{DaemonHttpState, require_async_db};

pub(super) mod acp_delete;
pub(super) mod acp_inspect;
pub(super) mod acp_sessions;
pub(super) mod acp_start;
pub(super) mod acp_transcript;
mod attach;
pub(super) mod codex_inspect;
pub(super) mod codex_transcript;
mod lookup;
pub(super) mod mutations;
pub(super) mod mutations_acp;
pub(crate) mod reads;
mod snapshots;

pub(crate) use lookup::{ensure_acp_agent, ensure_codex_agent, ensure_terminal_agent_async};
pub(crate) use snapshots::{
    acp_inspect_response, managed_agent_list_response_async, managed_agent_snapshot_async,
};

pub(super) fn managed_agent_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .merge(managed_agent_lifecycle_routes())
        .merge(terminal_agent_routes())
        .merge(codex_agent_routes())
        .merge(acp_agent_routes())
        .merge(acp_session_routes())
}

fn managed_agent_lifecycle_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(reads::get_managed_agents))
        .routes(routes!(mutations::post_terminal_agent_start))
        .routes(routes!(mutations::post_codex_agent_start))
        .routes(routes!(acp_start::post_acp_agent_start))
        .routes(routes!(
            reads::get_managed_agent,
            acp_delete::delete_acp_agent
        ))
}

fn terminal_agent_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(mutations::post_terminal_agent_input))
        .routes(routes!(mutations::post_terminal_agent_resize))
        .routes(routes!(mutations::post_terminal_agent_stop))
        .routes(routes!(mutations::post_terminal_agent_ready))
        .route(
            http_paths::MANAGED_AGENT_ATTACH,
            get(attach::get_terminal_agent_attach),
        )
}

fn codex_agent_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(mutations::post_codex_agent_steer))
        .routes(routes!(mutations::post_codex_agent_interrupt))
        .routes(routes!(mutations::post_codex_agent_approval))
        .routes(routes!(codex_inspect::get_codex_inspect))
        .routes(routes!(codex_transcript::get_codex_transcript))
}

fn acp_agent_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(mutations_acp::post_acp_permission))
        .routes(routes!(mutations_acp::post_acp_agent_prompt))
        .routes(routes!(mutations_acp::post_acp_agent_logout))
        .routes(routes!(acp_inspect::get_acp_inspect))
        .routes(routes!(acp_transcript::get_acp_transcript))
}

fn acp_session_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(acp_sessions::get_acp_sessions))
        .routes(routes!(acp_sessions::delete_acp_session))
        .routes(routes!(acp_sessions::post_acp_session_close))
}

// Cross-transport ACP policy lives here. HTTP and websocket wrappers still own
// auth, request parsing, timing, and serialization at the boundary.
pub(crate) fn ensure_acp_enabled() -> Result<(), CliError> {
    if acp_enabled_from_env() {
        Ok(())
    } else {
        Err(CliErrorKind::acp_disabled().into())
    }
}

pub(crate) async fn acp_transcript_response(
    state: &DaemonHttpState,
    session_id: &str,
) -> Result<AcpTranscriptResponse, CliError> {
    let async_db = require_async_db(state, "ACP transcript")?;
    session_acp_transcript_async(session_id, Some(async_db)).await
}

pub(crate) async fn run_terminal_agent_blocking<T, F>(
    state: &DaemonHttpState,
    operation: &'static str,
    work: F,
) -> Result<T, CliError>
where
    T: Send + 'static,
    F: FnOnce(AgentTuiManagerHandle) -> Result<T, CliError> + Send + 'static,
{
    let manager = state.agent_tui_manager.clone();
    spawn_blocking(move || work(manager))
        .await
        .unwrap_or_else(|error| {
            Err(CliErrorKind::workflow_io(format!(
                "managed terminal agent {operation} worker failed: {error}"
            ))
            .into())
        })
}

pub(crate) async fn run_codex_agent_blocking<T, F>(
    state: &DaemonHttpState,
    operation: &'static str,
    work: F,
) -> Result<T, CliError>
where
    T: Send + 'static,
    F: FnOnce(CodexControllerHandle) -> Result<T, CliError> + Send + 'static,
{
    let controller = state.codex_controller.clone();
    spawn_blocking(move || work(controller))
        .await
        .unwrap_or_else(|error| {
            Err(CliErrorKind::workflow_io(format!(
                "managed Codex agent {operation} worker failed: {error}"
            ))
            .into())
        })
}

pub(crate) async fn run_acp_agent_blocking<T, F>(
    state: &DaemonHttpState,
    operation: &'static str,
    work: F,
) -> Result<T, CliError>
where
    T: Send + 'static,
    F: FnOnce(AcpAgentManagerHandle) -> Result<T, CliError> + Send + 'static,
{
    let manager = state.acp_agent_manager.clone();
    spawn_blocking(move || work(manager))
        .await
        .unwrap_or_else(|error| {
            Err(CliErrorKind::workflow_io(format!(
                "managed ACP agent {operation} worker failed: {error}"
            ))
            .into())
        })
}

#[cfg(test)]
mod tests;
