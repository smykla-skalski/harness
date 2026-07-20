use axum::Router;
use axum::routing::{delete, get, post};
use tokio::task::spawn_blocking;

use crate::daemon::agent_acp::AcpAgentManagerHandle;
use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::protocol::{AcpTranscriptResponse, http_paths};
use crate::daemon::service::session_acp_transcript_async;
use crate::errors::{CliError, CliErrorKind};
use crate::feature_flags::acp_enabled_from_env;

use super::{DaemonHttpState, require_async_db};

mod acp_delete;
mod acp_inspect;
mod acp_sessions;
mod acp_start;
mod acp_transcript;
mod attach;
mod codex_inspect;
mod codex_transcript;
mod lookup;
mod mutations;
pub(crate) mod reads;
mod snapshots;

pub(crate) use lookup::{ensure_acp_agent, ensure_codex_agent, ensure_terminal_agent_async};
pub(crate) use snapshots::{
    acp_inspect_response, managed_agent_list_response_async, managed_agent_snapshot_async,
};

pub(super) fn managed_agent_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            http_paths::SESSION_MANAGED_AGENTS,
            get(reads::get_managed_agents),
        )
        .route(
            http_paths::SESSION_MANAGED_AGENTS_TERMINAL,
            post(mutations::post_terminal_agent_start),
        )
        .route(
            http_paths::SESSION_MANAGED_AGENTS_CODEX,
            post(mutations::post_codex_agent_start),
        )
        .route(
            http_paths::SESSION_MANAGED_AGENTS_ACP,
            post(acp_start::post_acp_agent_start),
        )
        .route(
            http_paths::MANAGED_AGENT_DETAIL,
            get(reads::get_managed_agent),
        )
        .route(
            http_paths::MANAGED_AGENT_DETAIL,
            delete(acp_delete::delete_acp_agent),
        )
        .route(
            http_paths::MANAGED_AGENT_INPUT,
            post(mutations::post_terminal_agent_input),
        )
        .route(
            http_paths::MANAGED_AGENT_RESIZE,
            post(mutations::post_terminal_agent_resize),
        )
        .route(
            http_paths::MANAGED_AGENT_STOP,
            post(mutations::post_terminal_agent_stop),
        )
        .route(
            http_paths::MANAGED_AGENT_READY,
            post(mutations::post_terminal_agent_ready),
        )
        .route(
            http_paths::MANAGED_AGENT_ATTACH,
            get(attach::get_terminal_agent_attach),
        )
        .route(
            http_paths::MANAGED_AGENT_STEER,
            post(mutations::post_codex_agent_steer),
        )
        .route(
            http_paths::MANAGED_AGENT_INTERRUPT,
            post(mutations::post_codex_agent_interrupt),
        )
        .route(
            http_paths::MANAGED_AGENT_APPROVAL,
            post(mutations::post_codex_agent_approval),
        )
        .route(
            http_paths::MANAGED_AGENT_ACP_PERMISSION,
            post(mutations::post_acp_permission),
        )
        .route(
            http_paths::MANAGED_AGENT_ACP_PROMPT,
            post(mutations::post_acp_agent_prompt),
        )
        .route(
            http_paths::MANAGED_AGENT_ACP_LOGOUT,
            post(mutations::post_acp_agent_logout),
        )
        .route(
            http_paths::MANAGED_AGENT_ACP_SESSIONS,
            get(acp_sessions::get_acp_sessions),
        )
        .route(
            http_paths::MANAGED_AGENT_ACP_SESSION_DELETE,
            delete(acp_sessions::delete_acp_session),
        )
        .route(
            http_paths::MANAGED_AGENT_ACP_SESSION_CLOSE,
            post(acp_sessions::post_acp_session_close),
        )
        .route(
            http_paths::MANAGED_AGENTS_CODEX_INSPECT,
            get(codex_inspect::get_codex_inspect),
        )
        .route(
            http_paths::MANAGED_AGENTS_CODEX_TRANSCRIPT,
            get(codex_transcript::get_codex_transcript),
        )
        .route(
            http_paths::MANAGED_AGENTS_ACP_INSPECT,
            get(acp_inspect::get_acp_inspect),
        )
        .route(
            http_paths::MANAGED_AGENTS_ACP_TRANSCRIPT,
            get(acp_transcript::get_acp_transcript),
        )
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
