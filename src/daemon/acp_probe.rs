//! Daemon-side access to the ACP runtime probe cache.
//!
//! The cache and the probing itself belong to `agents::acp`. What the daemon
//! adds is the routing: a sandboxed daemon cannot execute agent binaries, so it
//! asks the host bridge for the answer instead of probing locally. Only the
//! daemon knows it is sandboxed and only the daemon can reach the bridge, so
//! that decision lives here rather than in the agent domain.

use std::thread;

use harness_kernel::errors::CliError;
use tracing::warn;

use crate::agents::acp::probe::{
    AcpRuntimeProbeResponse, ProbeCacheRefresh, cached_probe_snapshot_with,
    spawn_local_probe_cache_refresh,
};
use crate::daemon::bridge::{BridgeCapability, BridgeClient};
use crate::daemon::sandboxed_from_env;
use crate::workspace::utc_now;

/// Return cached ACP probe results for the current daemon process.
#[must_use]
pub fn probe_acp_agents_cached() -> AcpRuntimeProbeResponse {
    cached_probe_snapshot().unwrap_or_else(pending_probe_response)
}

/// Return the latest cached ACP probe results without blocking request paths.
#[must_use]
pub fn cached_probe_snapshot() -> Option<AcpRuntimeProbeResponse> {
    cached_probe_snapshot_with(spawn_routed_probe_cache_refresh)
}

/// Best-effort cache warm-up for the ACP runtime probe.
pub fn schedule_probe_cache_refresh() {
    // Reading the snapshot is what starts a refresh when the cache is stale or
    // empty, which at boot it always is; the value itself is of no use here.
    drop(cached_probe_snapshot());
}

fn pending_probe_response() -> AcpRuntimeProbeResponse {
    AcpRuntimeProbeResponse {
        probes: Vec::new(),
        checked_at: utc_now(),
    }
}

fn spawn_routed_probe_cache_refresh(refresh: ProbeCacheRefresh) {
    if sandboxed_from_env() {
        spawn_bridge_probe_cache_refresh(refresh);
        return;
    }
    spawn_local_probe_cache_refresh(refresh);
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn spawn_bridge_probe_cache_refresh(refresh: ProbeCacheRefresh) {
    let result = thread::Builder::new()
        .name("acp-bridge-probe-refresh".to_string())
        .spawn(move || refresh_probe_cache_from_bridge(refresh));
    if let Err(error) = result {
        warn!(%error, "failed to spawn host bridge ACP probe refresh");
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn refresh_probe_cache_from_bridge(refresh: ProbeCacheRefresh) {
    match bridge_probe_snapshot() {
        Ok(Some(response)) => refresh.publish(response),
        Ok(None) => {}
        Err(error) => warn!(%error, "failed to refresh ACP runtime probe from host bridge"),
    }
}

fn bridge_probe_snapshot() -> Result<Option<AcpRuntimeProbeResponse>, CliError> {
    BridgeClient::for_capability(BridgeCapability::Acp).and_then(|bridge| bridge.acp_probe())
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;
    use crate::agents::acp::probe::{lock_probe_cache_for_tests, replace_probe_cache_for_tests};

    #[test]
    fn cached_probe_returns_pending_response_while_refresh_is_in_flight() {
        let _guard = lock_probe_cache_for_tests();
        replace_probe_cache_for_tests(None, Duration::ZERO, true);

        let response = probe_acp_agents_cached();

        assert!(response.probes.is_empty());
        assert!(!response.checked_at.is_empty());

        replace_probe_cache_for_tests(None, Duration::ZERO, false);
    }
}
