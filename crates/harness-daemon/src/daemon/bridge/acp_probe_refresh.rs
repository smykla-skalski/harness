//! Wires this crate's host-bridge client into `harness-daemon-acp-probe`'s
//! probe-cache routing.
//!
//! That crate owns the cache and the local/sandboxed routing decision but
//! cannot depend on this bridge client without a dependency cycle back onto
//! `harness-daemon`, so it takes the bridge-backed refresh as a plain
//! function pointer instead; this module supplies it.

use std::thread;

use harness_daemon_acp_probe::install_bridge_probe_refresh;
use harness_kernel::errors::CliError;
use tracing::warn;

use crate::agents::acp::probe::{AcpRuntimeProbeResponse, ProbeCacheRefresh};

use super::client::BridgeClient;
use super::types::BridgeCapability;

/// Registers this crate's bridge-backed refresh with `harness-daemon-acp-probe`.
///
/// Idempotent (the crate-side registration only ever takes its first call),
/// so every daemon start-up path may call this unconditionally before the
/// first probe cache read.
pub(crate) fn install_acp_probe_bridge_refresh() {
    install_bridge_probe_refresh(spawn_bridge_probe_cache_refresh);
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
