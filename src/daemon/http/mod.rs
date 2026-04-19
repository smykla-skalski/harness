use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use axum::Router;
use axum::body::Body;
use axum::extract::MatchedPath;
use axum::http::Request;
use axum::middleware::{self, Next};
use axum::response::Response;
use tokio::net::TcpListener;
#[cfg(test)]
use tokio::runtime::{Handle, RuntimeFlavor};
use tokio::sync::{broadcast, watch};
#[cfg(test)]
use tokio::task::block_in_place;
use tracing::Instrument as _;
use tracing::field::{Empty, display};

use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb, canonical_db_unavailable};
use crate::daemon::protocol::StreamEvent;
use crate::daemon::state::DaemonManifest;
use crate::daemon::websocket::ReplayBuffer;
use crate::errors::{CliError, CliErrorKind};
use crate::telemetry::{apply_parent_context_from_headers, current_trace_id, with_active_baggage};

mod agents;
mod auth;
mod core;
mod managed_agents;
mod response;
mod runtime_session;
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
        .merge(managed_agents::managed_agent_routes())
        .merge(signals::signal_routes())
        .merge(voice::voice_routes())
        .layer(middleware::from_fn(trace_http_request))
}

async fn trace_http_request(request: Request<Body>, next: Next) -> Response {
    let method = request.method().to_string();
    let route = request.extensions().get::<MatchedPath>().map_or_else(
        || request.uri().path().to_string(),
        |matched| matched.as_str().to_string(),
    );
    let request_id = response::extract_request_id(request.headers());
    let span = http_request_span(&method, &route, &request_id);
    let baggage = apply_parent_context_from_headers(&span, request.headers());
    let started_at = Instant::now();
    if let Some(trace_id) = span.in_scope(current_trace_id) {
        span.record("trace_id", display(trace_id));
    }
    let response = with_active_baggage(baggage, next.run(request).instrument(span.clone())).await;
    let status = response.status().as_u16();
    let duration_ms = u64::try_from(started_at.elapsed().as_millis()).unwrap_or(u64::MAX);
    span.record("http_status_code", display(status));
    span.record("duration_ms", display(duration_ms));
    span.record("http.response.status_code", display(status));
    response
}

fn http_request_span(method: &str, route: &str, request_id: &str) -> tracing::Span {
    let otel_name = format!("{method} {route}");
    tracing::info_span!(
        parent: None,
        "harness.daemon.http.request",
        otel.name = %otel_name,
        otel.kind = "server",
        http_method = %method,
        http_route = %route,
        request_id = %request_id,
        "http.request.method" = %method,
        "http.route" = %route,
        "url.path" = %route,
        "http.response.status_code" = Empty,
        http_status_code = Empty,
        duration_ms = Empty,
        trace_id = Empty
    )
}
