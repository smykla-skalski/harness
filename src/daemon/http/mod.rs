use std::sync::{Arc, Mutex, OnceLock};

use axum::Router;
use tokio::net::TcpListener;
use tokio::sync::{broadcast, watch};

use crate::errors::{CliError, CliErrorKind};

mod agents;
mod auth;
mod codex;
mod core;
mod response;
mod sessions;
mod signals;
mod stream;
mod tasks;
#[cfg(test)]
mod tests;
mod voice;

pub(crate) use auth::require_auth;

#[derive(Clone)]
pub struct DaemonHttpState {
    pub token: String,
    pub sender: broadcast::Sender<crate::daemon::protocol::StreamEvent>,
    pub manifest: crate::daemon::state::DaemonManifest,
    pub daemon_epoch: String,
    pub replay_buffer: Arc<Mutex<crate::daemon::websocket::ReplayBuffer>>,
    pub db: Arc<OnceLock<Arc<Mutex<crate::daemon::db::DaemonDb>>>>,
    pub codex_controller: crate::daemon::codex_controller::CodexControllerHandle,
    pub agent_tui_manager: crate::daemon::agent_tui::AgentTuiManagerHandle,
}

/// Serve the daemon's HTTP API.
///
/// # Errors
/// Returns `CliError` on listener failures.
pub async fn serve(
    listener: TcpListener,
    state: DaemonHttpState,
    mut shutdown_rx: watch::Receiver<bool>,
) -> Result<(), CliError> {
    let app = daemon_http_router().with_state(state);

    axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            if *shutdown_rx.borrow() {
                return;
            }
            while shutdown_rx.changed().await.is_ok() {
                if *shutdown_rx.borrow() {
                    break;
                }
            }
        })
        .await
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "serve daemon http api: {error}"
            )))
        })
}

fn daemon_http_router() -> Router<DaemonHttpState> {
    Router::new()
        .merge(core::core_routes())
        .merge(sessions::session_routes())
        .merge(tasks::task_routes())
        .merge(agents::agent_routes())
        .merge(agents::agent_tui_routes())
        .merge(signals::signal_routes())
        .merge(codex::codex_routes())
        .merge(voice::voice_routes())
}
