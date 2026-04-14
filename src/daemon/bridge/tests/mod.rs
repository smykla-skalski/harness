use super::bridge_state::{
    bridge_socket_path_for_root, group_container_root, unix_socket_path_fits,
};
use super::control::compute_bridge_manifest_update;
use super::runtime::BridgeSocketGuard;
use super::*;
use std::os::unix::net::UnixListener as StdUnixListener;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use fs2::FileExt;
use tempfile::tempdir;

mod cleanup_and_config;
mod legacy_server;
mod liveness;
mod locks;
mod manifest_and_paths;
mod support;
mod watcher;

use legacy_server::{LegacyBridgeServer, LegacyShutdownBehavior};
use support::{
    hold_bridge_lock, legacy_codex_capabilities, with_temp_daemon_root, write_fake_bridge_state,
};

#[test]
fn bridge_round_trip_smoke_covers_public_surface() {
    with_temp_daemon_root(|| {
        let capabilities = compiled_capabilities();
        assert!(capabilities.contains(&BridgeCapability::Codex));
        assert!(capabilities.contains(&BridgeCapability::AgentTui));

        let _server = LegacyBridgeServer::start(
            legacy_codex_capabilities(),
            LegacyShutdownBehavior::ExitAfter(Duration::ZERO),
        );

        assert!(bridge_state_path().is_file(), "bridge state should exist");
        let state = read_bridge_state().expect("read state").expect("state");
        let client = BridgeClient::from_state(&state).expect("client from state");
        let client_status = client.status().expect("client status");
        assert!(client_status.running);

        let capability_client =
            BridgeClient::for_capability(BridgeCapability::Codex).expect("codex client");
        let capability_status = capability_client.status().expect("capability status");
        assert_eq!(capability_status.pid, Some(999_999_999));

        let running = load_running_bridge_state(LivenessMode::HostAuthoritative)
            .expect("load running bridge")
            .expect("running bridge");
        assert_eq!(running.socket_path, state.socket_path);

        let manifest = host_bridge_manifest().expect("manifest");
        assert!(manifest.running);
        assert_eq!(
            codex_websocket_endpoint().expect("endpoint").as_deref(),
            Some("ws://127.0.0.1:4500")
        );

        let report = status_report().expect("status report");
        assert!(report.running);
        assert!(report.capabilities.contains_key(BRIDGE_CAPABILITY_CODEX));
    });
}
