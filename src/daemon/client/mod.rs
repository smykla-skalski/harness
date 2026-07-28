mod api;
mod connection;
mod http;

#[cfg(test)]
mod api_tests;
#[cfg(test)]
mod basic_tests;
#[cfg(test)]
mod discovery_tests;
// `pub`, not `pub(crate)`: the daemon-routing fixtures this crate's own unit
// tests use are also the only way `tests/integration_daemon.rs`'s
// `session_service_daemon_*` scenarios can fake a running daemon, since that
// binary links `harness` as an ordinary dependency where `cfg(test)` is
// never set. Gating on `daemon-runtime` rather than always-on keeps it out of
// the default-feature build the same way the rest of this module's
// daemon-only surface is gated.
#[cfg(any(test, feature = "daemon-runtime"))]
pub mod test_support;

use std::time::Duration;

/// HTTP client for daemon-first session mutations.
///
/// Reads the daemon manifest and auth token, then proxies session operations
/// through the daemon's HTTP API instead of writing files.
pub struct DaemonClient {
    endpoint: String,
    token: String,
    http: reqwest::Client,
}

impl DaemonClient {
    #[must_use]
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    #[must_use]
    pub fn token(&self) -> &str {
        &self.token
    }
}

const HEALTH_TIMEOUT: Duration = Duration::from_millis(500);
const API_READY_TIMEOUT: Duration = Duration::from_secs(2);
const API_READY_INTERVAL: Duration = Duration::from_millis(100);
const MUTATION_TIMEOUT: Duration = Duration::from_secs(5);
const SESSION_START_TIMEOUT: Duration = Duration::from_secs(30);
const TASK_BOARD_OPERATION_TIMEOUT: Duration = Duration::from_mins(2);
