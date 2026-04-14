use super::{
    HostBridgeManifest, compute_bridge_manifest_update, hold_bridge_lock, process_id, state,
    with_temp_daemon_root, write_fake_bridge_state,
};

#[test]
fn compute_bridge_manifest_update_returns_none_when_host_bridge_unchanged() {
    with_temp_daemon_root(|| {
        // No bridge running: host_bridge_manifest() returns default.
        let current = state::DaemonManifest {
            version: env!("CARGO_PKG_VERSION").to_string(),
            pid: process_id(),
            endpoint: "http://127.0.0.1:7070".to_string(),
            started_at: "2026-04-11T00:00:00Z".to_string(),
            token_path: "/tmp/token".to_string(),
            sandboxed: true,
            host_bridge: HostBridgeManifest::default(),
            revision: 1,
            updated_at: "2026-04-11T00:00:00Z".to_string(),
            binary_stamp: None,
        };
        // No bridge.json exists so host_bridge_manifest returns default.
        // current.host_bridge is already default, so no update needed.
        assert!(
            compute_bridge_manifest_update(&current).is_none(),
            "no update when host_bridge state is unchanged"
        );
    });
}

/// Direct regression test for the observed bug: watcher should publish a
/// running=true manifest update when bridge.lock is held, without needing
/// /bin/kill -0.
#[test]
fn compute_bridge_manifest_update_returns_some_when_lock_held_and_manifest_stale() {
    with_temp_daemon_root(|| {
        write_fake_bridge_state(99999999);
        let _flock = hold_bridge_lock();

        let current = state::DaemonManifest {
            version: env!("CARGO_PKG_VERSION").to_string(),
            pid: process_id(),
            endpoint: "http://127.0.0.1:7070".to_string(),
            started_at: "2026-04-11T00:00:00Z".to_string(),
            token_path: "/tmp/token".to_string(),
            sandboxed: true,
            // Manifest currently shows bridge as not running.
            host_bridge: HostBridgeManifest::default(),
            revision: 2,
            updated_at: "2026-04-11T00:00:00Z".to_string(),
            binary_stamp: None,
        };
        let updated = compute_bridge_manifest_update(&current)
            .expect("update should be produced when lock held and manifest stale");
        assert!(
            updated.host_bridge.running,
            "updated manifest should reflect running=true"
        );
    });
}
