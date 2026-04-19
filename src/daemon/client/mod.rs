mod api;
mod connection;
mod http;

#[cfg(test)]
mod basic_tests;
#[cfg(test)]
mod discovery_tests;
#[cfg(test)]
pub(crate) mod test_support;

pub use api::RuntimeSessionLookup;

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
