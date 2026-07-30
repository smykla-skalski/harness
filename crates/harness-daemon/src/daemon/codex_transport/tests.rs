use std::collections::BTreeMap;

use tempfile::tempdir;

use super::*;
use crate::daemon::bridge::{BridgeState, acquire_bridge_lock_exclusive, bridge_state_path};
use crate::daemon::state::HostBridgeCapabilityManifest;
use crate::infra::io::write_json_pretty;

fn with_isolated_env<F: FnOnce()>(f: F) {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "HARNESS_DAEMON_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_CODEX_WS_URL", None),
            ("XDG_DATA_HOME", None),
        ],
        f,
    );
}

fn write_bridge_state_for_test(endpoint: &str) {
    write_json_pretty(
        &bridge_state_path(),
        &BridgeState {
            socket_path: "/tmp/bridge.sock".to_string(),
            pid: std::process::id(),
            started_at: "2026-04-10T00:00:00Z".to_string(),
            token_path: "/tmp/auth-token".to_string(),
            capabilities: BTreeMap::from([(
                "codex".to_string(),
                HostBridgeCapabilityManifest {
                    enabled: true,
                    healthy: true,
                    transport: "websocket".to_string(),
                    endpoint: Some(endpoint.to_string()),
                    metadata: BTreeMap::from([("port".to_string(), "4500".to_string())]),
                },
            )]),
        },
    )
    .expect("write bridge state");
}

#[test]
fn defaults_stdio_when_unsandboxed() {
    with_isolated_env(|| {
        assert_eq!(codex_transport_from_env(false), CodexTransportKind::Stdio);
    });
}

#[test]
fn defaults_websocket_when_sandboxed() {
    with_isolated_env(|| {
        assert_eq!(
            codex_transport_from_env(true),
            CodexTransportKind::WebSocket {
                endpoint: DEFAULT_CODEX_WS_ENDPOINT.to_string(),
            },
        );
    });
}

#[test]
fn environment_override_precedes_bridge_state() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "HARNESS_DAEMON_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_CODEX_WS_URL", Some("ws://127.0.0.1:7777")),
            ("XDG_DATA_HOME", None),
        ],
        || {
            write_bridge_state_for_test("ws://127.0.0.1:9999");
            assert_eq!(
                codex_transport_from_env(true),
                CodexTransportKind::WebSocket {
                    endpoint: "ws://127.0.0.1:7777".to_string(),
                },
            );
        },
    );
}

#[test]
fn bridge_state_selects_websocket_without_override() {
    with_isolated_env(|| {
        write_bridge_state_for_test("ws://127.0.0.1:4501");
        let _lock = acquire_bridge_lock_exclusive().expect("bridge lock");
        assert_eq!(
            codex_transport_from_env(false),
            CodexTransportKind::WebSocket {
                endpoint: "ws://127.0.0.1:4501".to_string(),
            },
        );
    });
}

#[test]
fn rejects_nonlocal_override_when_sandboxed() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "HARNESS_DAEMON_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_CODEX_WS_URL", Some("ws://10.0.0.5:7000")),
            ("XDG_DATA_HOME", None),
        ],
        || {
            assert_eq!(
                codex_transport_from_env(true),
                CodexTransportKind::WebSocket {
                    endpoint: DEFAULT_CODEX_WS_ENDPOINT.to_string(),
                },
            );
        },
    );
}

#[test]
fn rejects_nonlocal_bridge_state_when_sandboxed() {
    with_isolated_env(|| {
        write_bridge_state_for_test("ws://10.0.0.5:7000");
        let _lock = acquire_bridge_lock_exclusive().expect("bridge lock");
        assert_eq!(
            codex_transport_from_env(true),
            CodexTransportKind::WebSocket {
                endpoint: DEFAULT_CODEX_WS_ENDPOINT.to_string(),
            },
        );
    });
}

#[test]
fn bridge_state_unblocks_unsandboxed_websocket() {
    with_isolated_env(|| {
        write_bridge_state_for_test("ws://127.0.0.1:4500");
        let _lock = acquire_bridge_lock_exclusive().expect("bridge lock");
        assert_eq!(
            codex_transport_from_env(false),
            CodexTransportKind::WebSocket {
                endpoint: "ws://127.0.0.1:4500".to_string(),
            },
        );
    });
}
