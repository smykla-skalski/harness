use std::thread;
use std::time::{Duration, Instant};

use tokio::runtime::Handle;

use super::{API_READY_INTERVAL, API_READY_TIMEOUT, DaemonClient, HEALTH_TIMEOUT};
use crate::daemon::{discovery, state};
use crate::infra::exec::RUNTIME;
use crate::infra::io::read_json_typed;

impl DaemonClient {
    /// Attempt to connect to a running daemon.
    ///
    /// Returns `None` if the daemon is not running or unreachable.
    ///
    /// This is intentionally uncached. Discovery can legitimately resolve to a
    /// different daemon root after env changes, daemon adoption, or a restart,
    /// and pinning the first successful client can route later operations into
    /// the wrong daemon.
    #[must_use]
    pub fn try_connect() -> Option<Self> {
        if daemon_client_allowed_in_current_context() {
            try_build_client()
        } else {
            log_daemon_client_discovery_skipped();
            None
        }
    }
}

pub(super) fn daemon_client_allowed_in_current_context() -> bool {
    Handle::try_current().is_err()
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_daemon_client_discovery_skipped() {
    tracing::debug!("skipping daemon client discovery inside active tokio runtime");
}

pub(super) fn try_build_client() -> Option<DaemonClient> {
    let root = discovery::running_daemon_location()?.root;
    let manifest: state::DaemonManifest = read_json_typed(&root.join("manifest.json")).ok()?;
    let token = fs_err::read_to_string(root.join("auth-token"))
        .ok()
        .map(|token| token.trim().to_string())
        .filter(|token| !token.is_empty())?;

    let http = reqwest::Client::builder().build().ok()?;
    let client = DaemonClient {
        endpoint: manifest.endpoint.clone(),
        token,
        http,
    };

    if check_daemon_health(&client, &manifest.endpoint)
        && wait_for_authenticated_api(&client, API_READY_TIMEOUT)
    {
        Some(client)
    } else {
        None
    }
}

fn check_daemon_health(client: &DaemonClient, endpoint: &str) -> bool {
    let start = Instant::now();
    let health_ok = RUNTIME.block_on(async {
        client
            .http
            .get(format!("{endpoint}/v1/health"))
            .bearer_auth(&client.token)
            .timeout(HEALTH_TIMEOUT)
            .send()
            .await
            .is_ok_and(|response| response.status().is_success())
    });
    let health_ms = u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX);
    log_health_result(endpoint, health_ms, health_ok);
    health_ok
}

fn log_health_result(endpoint: &str, health_ms: u64, ok: bool) {
    if ok {
        log_health_connected(endpoint, health_ms);
    } else {
        log_health_failed(endpoint, health_ms);
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "deadline-based warmup loop keeps daemon connection readiness explicit"
)]
pub(super) fn wait_for_authenticated_api(client: &DaemonClient, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if authenticated_api_ready(client) {
            return true;
        }
        if Instant::now() >= deadline {
            tracing::debug!(endpoint = client.endpoint, "daemon session API not ready");
            return false;
        }
        thread::sleep(API_READY_INTERVAL);
    }
}

fn authenticated_api_ready(client: &DaemonClient) -> bool {
    let url = format!("{}/v1/sessions", client.endpoint);
    RUNTIME.block_on(async {
        client
            .http
            .get(&url)
            .bearer_auth(&client.token)
            .timeout(HEALTH_TIMEOUT)
            .send()
            .await
            .is_ok_and(|response| response.status().is_success())
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_health_connected(endpoint: &str, health_ms: u64) {
    tracing::info!(endpoint, health_ms, "daemon client connected");
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_health_failed(endpoint: &str, health_ms: u64) {
    tracing::debug!(endpoint, health_ms, "daemon health check failed");
}
