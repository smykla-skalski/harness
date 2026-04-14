use super::*;

#[test]
fn host_bridge_manifest_reflects_running_bridge_state() {
    with_temp_daemon_root(|| {
        let state = BridgeState {
            socket_path: "/tmp/bridge.sock".to_string(),
            pid: process_id(),
            started_at: "2026-04-11T12:00:00Z".to_string(),
            token_path: "/tmp/auth-token".to_string(),
            capabilities: BTreeMap::from([(
                BRIDGE_CAPABILITY_AGENT_TUI.to_string(),
                HostBridgeCapabilityManifest {
                    enabled: true,
                    healthy: true,
                    transport: "unix".to_string(),
                    endpoint: Some("/tmp/bridge.sock".to_string()),
                    metadata: BTreeMap::from([("active_sessions".to_string(), "0".to_string())]),
                },
            )]),
        };
        write_bridge_state(&state).expect("write");
        // host_bridge_manifest uses LockOnly; hold the lock so it sees the
        // bridge as running (the previous behavior relied on pid_alive).
        let _flock = hold_bridge_lock();

        let manifest = host_bridge_manifest().expect("manifest");
        assert!(manifest.running);
        assert_eq!(manifest.socket_path.as_deref(), Some("/tmp/bridge.sock"));
        assert!(
            manifest
                .capabilities
                .contains_key(BRIDGE_CAPABILITY_AGENT_TUI)
        );
    });
}

#[test]
fn host_bridge_manifest_defaults_when_bridge_missing() {
    with_temp_daemon_root(|| {
        assert_eq!(
            host_bridge_manifest().expect("manifest"),
            HostBridgeManifest::default()
        );
    });
}

#[test]
fn bridge_client_for_capability_rejects_missing_capability() {
    with_temp_daemon_root(|| {
        let state = BridgeState {
            socket_path: "/tmp/bridge.sock".to_string(),
            pid: process_id(),
            started_at: "2026-04-11T12:00:00Z".to_string(),
            token_path: "/tmp/auth-token".to_string(),
            capabilities: BTreeMap::from([(
                BRIDGE_CAPABILITY_AGENT_TUI.to_string(),
                HostBridgeCapabilityManifest {
                    enabled: true,
                    healthy: true,
                    transport: "unix".to_string(),
                    endpoint: Some("/tmp/bridge.sock".to_string()),
                    metadata: BTreeMap::new(),
                },
            )]),
        };
        write_bridge_state(&state).expect("write");

        let error = BridgeClient::for_capability(BridgeCapability::Codex)
            .expect_err("codex capability should be rejected");
        assert_eq!(error.code(), "SANDBOX001");
        assert!(error.to_string().contains("codex.host-bridge"));
    });
}

#[test]
fn bridge_socket_guard_unlinks_on_drop() {
    let tmp = tempdir().expect("tempdir");
    let socket_path = tmp.path().join("fake.sock");
    fs::write(&socket_path, b"").expect("seed fake socket");
    assert!(socket_path.exists());

    {
        let _guard = BridgeSocketGuard::new(socket_path.clone());
    }

    assert!(
        !socket_path.exists(),
        "armed guard must unlink the socket file on drop"
    );
}

#[test]
fn bridge_socket_guard_disarmed_preserves_file() {
    let tmp = tempdir().expect("tempdir");
    let socket_path = tmp.path().join("fake.sock");
    fs::write(&socket_path, b"keep").expect("seed fake socket");

    {
        let mut guard = BridgeSocketGuard::new(socket_path.clone());
        guard.disarm();
    }

    assert!(
        socket_path.exists(),
        "disarmed guard must leave the socket file in place"
    );
    assert_eq!(
        fs::read(&socket_path).expect("read file"),
        b"keep",
        "file contents must be untouched"
    );
}

#[test]
fn bridge_socket_guard_drop_is_idempotent_when_file_missing() {
    let tmp = tempdir().expect("tempdir");
    let socket_path = tmp.path().join("never-existed.sock");
    assert!(!socket_path.exists());

    // Dropping the armed guard for a non-existent path must not panic
    // and must not emit a warn log (NotFound is intentionally silenced).
    let _guard = BridgeSocketGuard::new(socket_path);
}

#[test]
fn bridge_socket_path_falls_back_for_long_root() {
    let tmp = tempdir().expect("tempdir");
    let long_root = tmp.path().join(
        "very/long/path/for/a/daemon/root/that/would/overflow/the/unix/socket/path/limit/on/macos",
    );
    let path = bridge_socket_path_for_root(&long_root);
    assert!(path.starts_with("/tmp"));
    assert!(unix_socket_path_fits(&path));
}

#[test]
fn bridge_socket_fallback_uses_group_container_when_nested() {
    // Fully synthetic daemon root that mirrors the sandboxed shape
    // `{prefix}/Library/Group Containers/{group}/harness/daemon`.
    // Chosen so that `{daemon_root}/bridge.sock` exceeds the 103-byte
    // AF_UNIX `sun_path` limit (forcing the fallback to run) while the
    // group container root still has enough headroom for a shortened
    // hash suffix, independent of the host running the test.
    let group_container = PathBuf::from(
        "/private/sandbox-test-user/Library/Group Containers/Q498EB36N4.io.harnessmonitor",
    );
    let daemon_root = group_container.join("harness/daemon");

    let preferred = daemon_root.join(DEFAULT_BRIDGE_SOCKET_NAME);
    assert!(
        !unix_socket_path_fits(&preferred),
        "regression guard: preferred path must exceed the 103-byte limit so the fallback runs ({} bytes)",
        preferred.as_os_str().len(),
    );

    let path = bridge_socket_path_for_root(&daemon_root);
    assert!(
        unix_socket_path_fits(&path),
        "fallback path must fit within UNIX_SOCKET_PATH_LIMIT: {} ({} bytes)",
        path.display(),
        path.as_os_str().len(),
    );
    assert!(
        path.starts_with(&group_container),
        "fallback must land inside the group container, got {}",
        path.display()
    );
    assert!(
        !path.starts_with("/tmp"),
        "sandboxed daemons cannot reach /tmp; fallback must avoid it, got {}",
        path.display()
    );
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .expect("fallback socket file name");
    assert!(
        file_name.starts_with("h-") && file_name.ends_with(FALLBACK_BRIDGE_SOCKET_SUFFIX),
        "unexpected fallback file name: {file_name}"
    );
}

#[test]
fn group_container_root_detects_nested_path() {
    let daemon_root = PathBuf::from(
        "/Users/example/Library/Group Containers/Q498EB36N4.io.harnessmonitor/harness/daemon",
    );
    assert_eq!(
        group_container_root(&daemon_root),
        Some(PathBuf::from(
            "/Users/example/Library/Group Containers/Q498EB36N4.io.harnessmonitor"
        ))
    );
}

#[test]
fn group_container_root_returns_none_outside_container() {
    assert!(
        group_container_root(&PathBuf::from(
            "/Users/example/Library/Application Support/harness/daemon"
        ))
        .is_none()
    );
    assert!(group_container_root(&PathBuf::from("/tmp/harness/daemon")).is_none());
}
