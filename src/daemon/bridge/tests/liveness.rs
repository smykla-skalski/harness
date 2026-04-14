use super::{
    BRIDGE_CAPABILITY_CODEX, BTreeMap, BridgeCapability, BridgeClient, BridgeProof, Duration,
    Instant, LegacyBridgeServer, LegacyShutdownBehavior, LivenessMode, bridge_state_path,
    hold_bridge_lock, host_bridge_manifest, legacy_codex_capabilities, load_running_bridge_state,
    process_id, resolve_running_bridge, status_report, stop_bridge, wait_until_bridge_dead,
    with_temp_daemon_root, write_fake_bridge_state,
};

#[test]
fn load_running_bridge_state_returns_none_when_no_state_file() {
    with_temp_daemon_root(|| {
        assert!(
            load_running_bridge_state(LivenessMode::LockOnly)
                .expect("load")
                .is_none()
        );
        assert!(
            load_running_bridge_state(LivenessMode::HostAuthoritative)
                .expect("load")
                .is_none()
        );
    });
}

#[test]
fn load_running_bridge_state_returns_state_when_bridge_lock_held() {
    with_temp_daemon_root(|| {
        write_fake_bridge_state(99999999);
        let _flock = hold_bridge_lock();
        // Both modes return Some when the flock is held.
        assert!(
            load_running_bridge_state(LivenessMode::LockOnly)
                .expect("lock-only")
                .is_some()
        );
        assert!(
            load_running_bridge_state(LivenessMode::HostAuthoritative)
                .expect("host-auth")
                .is_some()
        );
    });
}

#[test]
fn load_running_bridge_state_returns_state_when_bridge_rpc_succeeds_without_lock() {
    with_temp_daemon_root(|| {
        let _server = LegacyBridgeServer::start(
            BTreeMap::new(),
            LegacyShutdownBehavior::ExitAfter(Duration::ZERO),
        );
        assert!(
            load_running_bridge_state(LivenessMode::LockOnly)
                .expect("lock-only")
                .is_some()
        );
        assert!(
            load_running_bridge_state(LivenessMode::HostAuthoritative)
                .expect("host-auth")
                .is_some()
        );
    });
}

#[test]
fn load_running_bridge_state_returns_none_when_neither_lock_nor_pid_live() {
    with_temp_daemon_root(|| {
        // pid 99999999 is definitely not alive.
        write_fake_bridge_state(99999999);
        assert!(
            load_running_bridge_state(LivenessMode::LockOnly)
                .expect("lock-only")
                .is_none()
        );
        assert!(
            load_running_bridge_state(LivenessMode::HostAuthoritative)
                .expect("host-auth")
                .is_none()
        );
    });
}

/// The critical regression test. The consumer path must never delete
/// bridge.json regardless of what it finds. This is the test that would
/// have caught the original v19.6.0 bug.
#[test]
fn load_running_bridge_state_does_not_delete_state_file() {
    with_temp_daemon_root(|| {
        write_fake_bridge_state(99999999);
        let _ = load_running_bridge_state(LivenessMode::LockOnly).expect("lock-only");
        assert!(
            bridge_state_path().exists(),
            "bridge.json must survive a LockOnly load with a dead pid"
        );
        let _ = load_running_bridge_state(LivenessMode::HostAuthoritative).expect("host-auth");
        assert!(
            bridge_state_path().exists(),
            "bridge.json must survive a HostAuthoritative load with a dead pid"
        );
    });
}

#[test]
fn load_running_bridge_state_lock_only_ignores_pid_alive_fallback() {
    with_temp_daemon_root(|| {
        // Use the current process pid — guaranteed alive under /bin/kill -0.
        write_fake_bridge_state(process_id());
        // LockOnly must return None because no flock is held, even though
        // the pid is alive.
        assert!(
            load_running_bridge_state(LivenessMode::LockOnly)
                .expect("lock-only")
                .is_none(),
            "LockOnly must not fall back to pid_alive"
        );
        // HostAuthoritative must return Some via the pid fallback.
        assert!(
            load_running_bridge_state(LivenessMode::HostAuthoritative)
                .expect("host-auth")
                .is_some(),
            "HostAuthoritative must fall back to pid_alive when no lock held"
        );
    });
}

#[test]
fn load_running_bridge_state_host_authoritative_returns_state_when_only_pid_alive() {
    with_temp_daemon_root(|| {
        // Simulates a pre-19.7.0 bridge: state file present, no bridge.lock.
        write_fake_bridge_state(process_id());
        assert!(
            load_running_bridge_state(LivenessMode::HostAuthoritative)
                .expect("host-auth")
                .is_some(),
            "backward-compat: HostAuthoritative must return state when only pid is alive"
        );
    });
}

#[test]
fn host_bridge_manifest_uses_rpc_for_legacy_bridge_without_lock() {
    with_temp_daemon_root(|| {
        let _server = LegacyBridgeServer::start(
            legacy_codex_capabilities(),
            LegacyShutdownBehavior::ExitAfter(Duration::ZERO),
        );
        let manifest = host_bridge_manifest().expect("manifest");
        assert!(manifest.running);
        assert_eq!(
            manifest
                .capabilities
                .get(BRIDGE_CAPABILITY_CODEX)
                .and_then(|capability| capability.endpoint.as_deref()),
            Some("ws://127.0.0.1:4500")
        );
    });
}

#[test]
fn status_report_uses_rpc_when_sandboxed_legacy_bridge_is_live() {
    with_temp_daemon_root(|| {
        let _server = LegacyBridgeServer::start(
            BTreeMap::new(),
            LegacyShutdownBehavior::ExitAfter(Duration::ZERO),
        );
        temp_env::with_var("HARNESS_SANDBOXED", Some("1"), || {
            let report = status_report().expect("status");
            assert!(report.running);
            assert_eq!(report.pid, Some(999_999_999));
        });
    });
}

#[test]
fn bridge_client_for_capability_accepts_live_legacy_bridge_without_lock() {
    with_temp_daemon_root(|| {
        let _server = LegacyBridgeServer::start(
            legacy_codex_capabilities(),
            LegacyShutdownBehavior::ExitAfter(Duration::ZERO),
        );
        let client = BridgeClient::for_capability(BridgeCapability::Codex).expect("codex client");
        let report = client.status().expect("status");
        assert!(report.running);
        assert!(report.capabilities.contains_key(BRIDGE_CAPABILITY_CODEX));
    });
}

#[test]
fn wait_until_bridge_dead_returns_error_when_rpc_proof_stays_live_in_sandbox() {
    with_temp_daemon_root(|| {
        let _server = LegacyBridgeServer::start(BTreeMap::new(), LegacyShutdownBehavior::Ignore);
        temp_env::with_var("HARNESS_SANDBOXED", Some("1"), || {
            let running = resolve_running_bridge(LivenessMode::HostAuthoritative)
                .expect("resolve running bridge")
                .expect("running bridge");
            assert_eq!(running.proof, BridgeProof::Rpc);
            let error = wait_until_bridge_dead(&running, Duration::from_millis(150))
                .expect_err("rpc proof should remain live");
            assert!(error.to_string().contains("still responding"));
        });
    });
}

#[test]
fn stop_bridge_waits_for_rpc_proof_to_disappear_before_clearing_state() {
    with_temp_daemon_root(|| {
        let _server = LegacyBridgeServer::start(
            legacy_codex_capabilities(),
            LegacyShutdownBehavior::ExitAfter(Duration::from_millis(250)),
        );
        let started = Instant::now();
        let report = stop_bridge().expect("stop bridge");
        assert!(
            started.elapsed() >= Duration::from_millis(200),
            "stop_bridge should wait until the RPC proof disappears"
        );
        assert!(
            !bridge_state_path().exists(),
            "bridge state should be cleared"
        );
        assert!(!report.running);
    });
}
