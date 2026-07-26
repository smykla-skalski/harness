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
    AcpRuntimeProbeResponse, cached_probe_snapshot_with, finish_probe_cache_refresh,
    probe_acp_agents_cached_with, schedule_probe_cache_refresh_with,
    spawn_local_probe_cache_refresh,
};
use crate::daemon::bridge::{BridgeCapability, BridgeClient};
use crate::daemon::sandboxed_from_env;

/// Return cached ACP probe results for the current daemon process.
#[must_use]
pub fn probe_acp_agents_cached() -> AcpRuntimeProbeResponse {
    probe_acp_agents_cached_with(spawn_routed_probe_cache_refresh)
}

/// Return the latest cached ACP probe results without blocking request paths.
#[must_use]
pub fn cached_probe_snapshot() -> Option<AcpRuntimeProbeResponse> {
    cached_probe_snapshot_with(spawn_routed_probe_cache_refresh)
}

/// Best-effort cache warm-up for the ACP runtime probe.
pub fn schedule_probe_cache_refresh() {
    schedule_probe_cache_refresh_with(spawn_routed_probe_cache_refresh);
}

fn spawn_routed_probe_cache_refresh() {
    if sandboxed_from_env() {
        spawn_bridge_probe_cache_refresh();
        return;
    }
    spawn_local_probe_cache_refresh();
}

fn spawn_bridge_probe_cache_refresh() {
    let result = thread::Builder::new()
        .name("acp-bridge-probe-refresh".to_string())
        .spawn(refresh_probe_cache_from_bridge);
    if let Err(error) = result {
        finish_probe_cache_refresh(None);
        warn!(%error, "failed to spawn host bridge ACP probe refresh");
    }
}

fn refresh_probe_cache_from_bridge() {
    match bridge_probe_snapshot() {
        Ok(response) => finish_probe_cache_refresh(response),
        Err(error) => {
            finish_probe_cache_refresh(None);
            warn!(%error, "failed to refresh ACP runtime probe from host bridge");
        }
    }
}

fn bridge_probe_snapshot() -> Result<Option<AcpRuntimeProbeResponse>, CliError> {
    BridgeClient::for_capability(BridgeCapability::Acp).and_then(|bridge| bridge.acp_probe())
}
