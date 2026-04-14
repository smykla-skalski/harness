use super::{
    BRIDGE_CAPABILITY_CODEX, BTreeMap, BridgeState, FileExt, HostBridgeCapabilityManifest,
    bridge_lock_path, state, tempdir, write_bridge_state,
};

pub(super) fn with_temp_daemon_root<F: FnOnce()>(f: F) {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "HARNESS_DAEMON_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_SANDBOXED", None),
            ("XDG_DATA_HOME", None),
        ],
        f,
    );
}

pub(super) fn write_fake_bridge_state(pid: u32) {
    state::ensure_daemon_dirs().expect("dirs");
    let bridge_state = BridgeState {
        socket_path: "/tmp/fake-bridge.sock".to_string(),
        pid,
        started_at: "2026-04-11T17:00:00Z".to_string(),
        token_path: "/tmp/fake-token".to_string(),
        capabilities: BTreeMap::new(),
    };
    write_bridge_state(&bridge_state).expect("write bridge state");
}

/// Acquire an exclusive flock by hand and keep the file open so the flock
/// persists for the duration of the caller's scope. Mirrors the
/// `fake_running_daemon` pattern in discovery tests.
pub(super) fn hold_bridge_lock() -> std::fs::File {
    state::ensure_daemon_dirs().expect("dirs");
    let path = bridge_lock_path();
    let file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(&path)
        .expect("open bridge lock");
    file.try_lock_exclusive().expect("flock bridge lock");
    file
}

pub(super) fn legacy_codex_capabilities() -> BTreeMap<String, HostBridgeCapabilityManifest> {
    BTreeMap::from([(
        BRIDGE_CAPABILITY_CODEX.to_string(),
        HostBridgeCapabilityManifest {
            enabled: true,
            healthy: true,
            transport: "websocket".to_string(),
            endpoint: Some("ws://127.0.0.1:4500".to_string()),
            metadata: BTreeMap::from([("port".to_string(), "4500".to_string())]),
        },
    )])
}
