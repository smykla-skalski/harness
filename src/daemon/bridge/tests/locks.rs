use super::*;

// --- bridge.lock unit tests ---

#[test]
fn acquire_bridge_lock_succeeds_when_unheld() {
    with_temp_daemon_root(|| {
        let _guard = acquire_bridge_lock_exclusive().expect("first acquire should succeed");
        assert!(bridge_lock_path().exists(), "lock file should exist");
    });
}

#[test]
fn acquire_bridge_lock_fails_when_another_holder_exists() {
    with_temp_daemon_root(|| {
        let _guard = acquire_bridge_lock_exclusive().expect("first acquire");
        let error = acquire_bridge_lock_exclusive().expect_err("second acquire should fail");
        assert!(
            error.to_string().contains("bridge"),
            "error should mention bridge: {error}"
        );
    });
}

#[test]
fn bridge_lock_guard_releases_on_drop() {
    with_temp_daemon_root(|| {
        let guard = acquire_bridge_lock_exclusive().expect("acquire");
        drop(guard);
        let _guard2 =
            acquire_bridge_lock_exclusive().expect("re-acquire after drop should succeed");
    });
}

#[test]
fn bridge_lock_is_held_is_false_when_no_holder() {
    with_temp_daemon_root(|| {
        assert!(
            !state::flock_is_held_at(&bridge_lock_path()),
            "no holder yet"
        );
    });
}

#[test]
fn bridge_lock_is_held_is_true_while_guard_is_alive() {
    with_temp_daemon_root(|| {
        let guard = acquire_bridge_lock_exclusive().expect("acquire");
        assert!(
            state::flock_is_held_at(&bridge_lock_path()),
            "should be held"
        );
        drop(guard);
        assert!(
            !state::flock_is_held_at(&bridge_lock_path()),
            "should be released"
        );
    });
}

#[test]
fn clear_bridge_state_removes_lock_file() {
    with_temp_daemon_root(|| {
        state::ensure_daemon_dirs().expect("dirs");
        // Create the lock file as if the bridge had been running.
        std::fs::write(bridge_lock_path(), "").expect("create lock file");
        clear_bridge_state().expect("clear");
        assert!(!bridge_lock_path().exists(), "lock file should be removed");
    });
}
