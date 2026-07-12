//! Daemon manifest construction for the serve entrypoint.

use std::process::id as process_id;

use crate::daemon::bridge;
use crate::daemon::state::{self, DaemonManifest};
use crate::errors::CliError;
use crate::workspace::utc_now;

use super::binary_stamp::current_binary_stamp;

/// Build the daemon manifest for `endpoint` without advertising readiness.
pub(super) fn build_manifest(endpoint: &str, sandboxed: bool) -> Result<DaemonManifest, CliError> {
    Ok(DaemonManifest {
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
    })
}

/// Publish a fully initialized daemon and record its listening event.
pub(super) fn persist_manifest(manifest: &DaemonManifest) -> Result<DaemonManifest, CliError> {
    let persisted = state::write_manifest(manifest)?;
    state::append_event(
        "info",
        &format!("daemon listening on {}", manifest.endpoint),
    )?;
    Ok(persisted)
}

#[cfg(test)]
mod tests {
    use harness_testkit::with_isolated_harness_env;
    use tempfile::tempdir;

    use super::*;
    use crate::daemon::state::{DaemonOwnership, HostBridgeManifest};

    #[test]
    fn persist_manifest_returns_the_snapshot_written_to_disk() {
        let tmp = tempdir().expect("tempdir");
        with_isolated_harness_env(tmp.path(), || {
            let manifest = DaemonManifest {
                version: "46.0.0".into(),
                pid: 42,
                endpoint: "http://127.0.0.1:4242".into(),
                started_at: "2026-07-12T00:00:00Z".into(),
                token_path: "/tmp/harness-token".into(),
                sandboxed: true,
                host_bridge: HostBridgeManifest::default(),
                revision: 0,
                updated_at: String::new(),
                binary_stamp: None,
                ownership: DaemonOwnership::Managed,
            };

            let persisted = persist_manifest(&manifest).expect("persist manifest");
            let loaded = state::load_manifest()
                .expect("load manifest")
                .expect("persisted manifest");

            assert_eq!(persisted.revision, 1);
            assert!(!persisted.updated_at.is_empty());
            assert_eq!(persisted.revision, loaded.revision);
            assert_eq!(persisted.updated_at, loaded.updated_at);
        });
    }
}
