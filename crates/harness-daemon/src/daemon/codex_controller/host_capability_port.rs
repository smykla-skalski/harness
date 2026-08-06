use std::time::Duration;

use harness_daemon_codex::CodexHostCapability;
use harness_kernel::errors::CliError;
use harness_protocol::daemon::HostBridgeCapabilityManifest;

use crate::daemon::bridge;

/// Zero-sized implementor of [`CodexHostCapability`]: the real state lives in
/// the unified host bridge's own state file and TCP endpoint, not in this
/// type, so there's nothing to hold.
pub struct HostBridgeCapability;

impl CodexHostCapability for HostBridgeCapability {
    fn running_codex_capability(&self) -> Result<Option<HostBridgeCapabilityManifest>, CliError> {
        bridge::running_codex_capability()
    }

    fn probe_codex_readiness(&self, endpoint: &str, timeout: Duration) -> Result<(), String> {
        bridge::probe_codex_readiness(endpoint, timeout)
    }
}
