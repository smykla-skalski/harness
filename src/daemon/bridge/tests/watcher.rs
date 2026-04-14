use super::{
    HostBridgeManifest, compute_bridge_manifest_update, hold_bridge_lock, process_id, state,
    with_temp_daemon_root, write_fake_bridge_state,
};
use serde_json::json;

fn bridge_manifest_fixture(
    revision: u64,
    host_bridge: HostBridgeManifest,
) -> state::DaemonManifest {
    serde_json::from_value(json!({
        "version": env!("CARGO_PKG_VERSION"),
        "pid": process_id(),
        "endpoint": "http://127.0.0.1:7070",
        "started_at": "2026-04-11T00:00:00Z",
        "token_path": "/tmp/token",
        "sandboxed": true,
        "host_bridge": host_bridge,
        "revision": revision,
        "updated_at": "2026-04-11T00:00:00Z"
    }))
    .expect("manifest fixture")
}

#[test]
fn compute_bridge_manifest_update_returns_none_when_host_bridge_unchanged() {
    with_temp_daemon_root(|| {
        // No bridge running: host_bridge_manifest() returns default.
        let current = bridge_manifest_fixture(1, HostBridgeManifest::default());
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

        // Manifest currently shows bridge as not running.
        let current = bridge_manifest_fixture(2, HostBridgeManifest::default());
        let updated = compute_bridge_manifest_update(&current)
            .expect("update should be produced when lock held and manifest stale");
        assert!(
            updated.host_bridge.running,
            "updated manifest should reflect running=true"
        );
    });
}
