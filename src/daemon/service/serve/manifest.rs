//! Daemon manifest construction for the serve entrypoint.

use std::process::id as process_id;

use crate::daemon::bridge;
use crate::daemon::state::{self, DaemonManifest};
use crate::errors::CliError;
use crate::workspace::utc_now;

use super::binary_stamp::current_binary_stamp;

/// Build the daemon manifest for `endpoint`, persist it, and record the
/// listening event. `write_manifest` bumps `revision` and `updated_at`, so the
/// literal only seeds placeholders for those fields.
pub(super) fn build_and_persist_manifest(
    endpoint: &str,
    sandboxed: bool,
) -> Result<DaemonManifest, CliError> {
    let manifest = DaemonManifest {
        version: env!("CARGO_PKG_VERSION").to_string(),
        pid: process_id(),
        endpoint: endpoint.to_string(),
        started_at: utc_now(),
        token_path: state::auth_token_path().display().to_string(),
        sandboxed,
        host_bridge: bridge::host_bridge_manifest_with_discovery()?,
        revision: 0,
        updated_at: String::new(),
        binary_stamp: current_binary_stamp(),
        ownership: state::DaemonOwnership::from_env_or_default(),
    };
    state::write_manifest(&manifest)?;
    state::append_event("info", &format!("daemon listening on {endpoint}"))?;
    Ok(manifest)
}
