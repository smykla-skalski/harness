use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use axum::Router;
use tokio::net::TcpListener;
#[cfg(test)]
use tokio::runtime::{Handle, RuntimeFlavor};
use tokio::sync::{broadcast, watch};
#[cfg(test)]
use tokio::task::block_in_place;

use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb, canonical_db_unavailable};
use crate::daemon::protocol::StreamEvent;
use crate::daemon::state::DaemonManifest;
use crate::daemon::websocket::ReplayBuffer;
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

#[derive(Clone, Default)]
pub struct AsyncDaemonDbSlot {
    inner: Arc<OnceLock<Arc<AsyncDaemonDb>>>,
}

impl AsyncDaemonDbSlot {
    #[must_use]
    pub fn empty() -> Self {
        Self::default()
    }

    #[must_use]
    pub(crate) fn from_inner(inner: Arc<OnceLock<Arc<AsyncDaemonDb>>>) -> Self {
        Self { inner }
    }

    #[must_use]
    pub(crate) fn get(&self) -> Option<&Arc<AsyncDaemonDb>> {
        self.inner.get()
    }
}

pub(crate) fn require_async_db<'a>(
    state: &'a DaemonHttpState,
    operation: &str,
) -> Result<&'a AsyncDaemonDb, CliError> {
    state
        .async_db
        .get()
        .map(AsRef::as_ref)
        .ok_or_else(|| canonical_db_unavailable(operation))
}

#[cfg(test)]
pub(crate) fn connect_async_db_for_tests(path: &std::path::Path) -> Arc<AsyncDaemonDb> {
    let path = path.to_path_buf();

    match Handle::try_current() {
        Ok(current) => match current.runtime_flavor() {
            RuntimeFlavor::MultiThread => {
                let runtime = current.clone();
                let path = path.clone();
                block_in_place(move || {
                    runtime.block_on(async move {
                        Arc::new(
                            AsyncDaemonDb::connect(&path)
                                .await
                                .expect("open async daemon db"),
                        )
                    })
                })
            }
            RuntimeFlavor::CurrentThread => std::thread::spawn(move || {
                tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("build async daemon db test runtime")
                    .block_on(async move {
                        Arc::new(
                            AsyncDaemonDb::connect(&path)
                                .await
                                .expect("open async daemon db"),
                        )
                    })
            })
            .join()
            .expect("join async daemon db thread"),
            _ => current.block_on(async move {
                Arc::new(
                    AsyncDaemonDb::connect(&path)
                        .await
                        .expect("open async daemon db"),
                )
            }),
        },
        Err(_) => tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("build async daemon db test runtime")
            .block_on(async move {
                Arc::new(
                    AsyncDaemonDb::connect(&path)
                        .await
                        .expect("open async daemon db"),
                )
            }),
    }
}

#[derive(Clone)]
pub struct DaemonHttpState {
    pub token: String,
    pub sender: broadcast::Sender<StreamEvent>,
    pub manifest: DaemonManifest,
    pub daemon_epoch: String,
    pub replay_buffer: Arc<Mutex<ReplayBuffer>>,
    pub db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    pub async_db: AsyncDaemonDbSlot,
    pub db_path: Option<PathBuf>,
    pub codex_controller: CodexControllerHandle,
    pub agent_tui_manager: AgentTuiManagerHandle,
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
