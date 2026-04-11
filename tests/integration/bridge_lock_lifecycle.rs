//! End-to-end coverage for `bridge.lock` acquisition and the regression where
//! the sandboxed daemon deleted `bridge.json` on a spurious watcher trigger.
//!
//! Commit 2 tests: lock lifecycle during `harness bridge start`.
//! Commit 3 tests: `bridge_json_survives_synthetic_watcher_trigger`.

#![cfg(target_os = "macos")]

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const BRIDGE_WAIT_TIMEOUT: Duration = Duration::from_secs(15);
const BRIDGE_POLL_INTERVAL: Duration = Duration::from_millis(100);

/// Wait until a file exists at `path` or the timeout expires.
fn wait_for_file(path: &std::path::Path) -> Result<(), String> {
    let deadline = Instant::now() + BRIDGE_WAIT_TIMEOUT;
    loop {
        if path.exists() {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "file did not appear at {} within {:?}",
                path.display(),
                BRIDGE_WAIT_TIMEOUT,
            ));
        }
        thread::sleep(BRIDGE_POLL_INTERVAL);
    }
}

/// Wait until `predicate` returns true or the timeout expires.
fn wait_until<F: Fn() -> bool>(predicate: F) -> Result<(), String> {
    let deadline = Instant::now() + BRIDGE_WAIT_TIMEOUT;
    loop {
        if predicate() {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "condition not met within {:?}",
                BRIDGE_WAIT_TIMEOUT
            ));
        }
        thread::sleep(BRIDGE_POLL_INTERVAL);
    }
}

fn harness_binary() -> PathBuf {
    assert_cmd::cargo::cargo_bin("harness")
}

/// `harness bridge start` must create `bridge.lock` and hold it exclusively
/// while serving. A second concurrent `harness bridge start` must fail with
/// a non-zero exit code.
#[test]
fn bridge_start_holds_exclusive_bridge_lock_while_serving() {
    use fs2::FileExt;
    use tempfile::tempdir;

    let tmp = tempdir().expect("tempdir");
    let daemon_data_home = tmp.path().to_str().expect("utf8").to_string();

    let mut first_bridge = Command::new(harness_binary())
        .args(["bridge", "start", "--capability", "agent-tui"])
        .env("HARNESS_DAEMON_DATA_HOME", &daemon_data_home)
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_SANDBOXED")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn first bridge");

    let daemon_root = tmp.path().join("harness").join("daemon");
    let lock_path = daemon_root.join("bridge.lock");
    let state_path = daemon_root.join("bridge.json");

    // Wait until the bridge is up (state file written and lock held).
    let ready = wait_for_file(&state_path).and_then(|()| {
        wait_until(|| {
            let Ok(file) = std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(&lock_path)
            else {
                return false;
            };
            file.try_lock_exclusive()
                .map(|()| {
                    let _ = file.unlock();
                    false
                })
                .unwrap_or(true) // WouldBlock means held
        })
    });

    if ready.is_err() {
        let _ = first_bridge.kill();
        let _ = first_bridge.wait();
        ready.expect("bridge lock was not held within timeout");
    }

    // Second bridge start must fail because the lock is held.
    let second_status = Command::new(harness_binary())
        .args(["bridge", "start", "--capability", "agent-tui"])
        .env("HARNESS_DAEMON_DATA_HOME", &daemon_data_home)
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_SANDBOXED")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .expect("spawn second bridge");

    let _ = first_bridge.kill();
    let _ = first_bridge.wait();

    assert!(
        !second_status.success(),
        "second bridge start should fail while first holds the lock"
    );
}
