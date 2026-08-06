use std::time::Duration;

use harness_kernel::errors::CliError;
use harness_protocol::daemon::HostBridgeCapabilityManifest;

/// Whether the unified host bridge has a live, reachable Codex backend.
/// `harness-daemon` implements this against `daemon::bridge`'s state-file
/// reads and TCP probe; this crate never touches the bridge directly.
pub trait CodexHostCapability {
    /// # Errors
    /// Returns [`CliError`] when the bridge state file cannot be read.
    fn running_codex_capability(&self) -> Result<Option<HostBridgeCapabilityManifest>, CliError>;

    /// # Errors
    /// Returns a description of why the endpoint isn't reachable.
    fn probe_codex_readiness(&self, endpoint: &str, timeout: Duration) -> Result<(), String>;
}
