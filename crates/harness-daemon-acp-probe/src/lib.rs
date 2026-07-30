//! Daemon-side access to the ACP runtime probe cache.
//!
//! The cache and the probing itself belong to `harness_agents::acp::probe`.
//! What this crate adds is the routing: a sandboxed daemon cannot execute
//! agent binaries, so it asks the host bridge for the answer instead of
//! probing locally. Only the real daemon knows it is sandboxed and only it
//! can reach the bridge, and the bridge client has no crate of its own yet,
//! so depending on it directly here would make `harness-daemon` (which
//! depends on this crate for the functions below) a cycle.
//! `install_bridge_probe_refresh` lets the daemon plug that one call in
//! instead, keeping this crate agnostic of how the bridge works.

use std::sync::OnceLock;

use harness_agents::acp::probe::{
    AcpRuntimeProbeResponse, ProbeCacheRefresh, cached_probe_snapshot_with,
    spawn_local_probe_cache_refresh,
};
use harness_workspace::workspace::utc_now;
use tracing::warn;

static BRIDGE_PROBE_REFRESH: OnceLock<fn(ProbeCacheRefresh)> = OnceLock::new();

/// Registers the daemon's bridge-backed refresh for a sandboxed process.
///
/// Call once during daemon start-up, before the first probe cache read. A
/// later call is a no-op: only the first registration ever takes effect.
pub fn install_bridge_probe_refresh(refresh: fn(ProbeCacheRefresh)) {
    let _ = BRIDGE_PROBE_REFRESH.set(refresh);
}

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
        if let Some(bridge_refresh) = BRIDGE_PROBE_REFRESH.get() {
            bridge_refresh(refresh);
            return;
        }
        // The real daemon always installs a refresh before serving its first
        // request; reaching here means it did not, so falling back to a
        // local probe beats leaving the refresh permanently unpaid.
        warn!("sandboxed daemon has no bridge probe refresh installed");
    }
    spawn_local_probe_cache_refresh(refresh);
}

// Mirrors the daemon's and the host bridge's own copy of this same check:
// trivial and process-wide, so a shared dependency for one env read buys
// nothing a third copy doesn't already give for free.
fn sandboxed_from_env() -> bool {
    std::env::var("HARNESS_SANDBOXED")
        .ok()
        .is_some_and(|value| {
            matches!(
                value.trim(),
                "1" | "true" | "TRUE" | "yes" | "YES" | "on" | "ON"
            )
        })
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use harness_agents::acp::probe::{lock_probe_cache_for_tests, replace_probe_cache_for_tests};

    use super::*;

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
