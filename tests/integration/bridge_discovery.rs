//! End-to-end coverage for daemon root discovery during
//! `harness bridge start`.
//!
//! Regression test for the bug where a plain terminal running
//! `harness bridge start` without `HARNESS_APP_GROUP_ID` would write
//! `bridge.json` to the XDG default while the sandboxed managed daemon
//! watches the macOS app group container.
//!
//! The test stands up a fake running daemon at the group container path
//! (an empty `daemon.lock` file with an exclusive flock held by the parent
//! test process) and a distinct empty `XDG_DATA_HOME`. It then runs
//! `harness bridge start` in a subprocess with no env vars pointing at
//! either location and asserts the bridge state file lands at the
//! (adopted) group container path.

#![cfg(target_os = "macos")]

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use fs2::FileExt;
use tempfile::tempdir;

use super::helpers::ManagedChild;

const BRIDGE_WAIT_TIMEOUT: Duration = Duration::from_secs(15);
const BRIDGE_POLL_INTERVAL: Duration = Duration::from_millis(100);
const HARNESS_MONITOR_APP_GROUP_ID: &str = "Q498EB36N4.io.harnessmonitor";

#[test]
fn bridge_start_adopts_group_container_when_xdg_is_empty() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path();
    // `XDG_DATA_HOME` is the natural default when no app-group env is set.
    // Point it at an empty subdirectory so the subprocess's natural default
    // has no running daemon and discovery must step in.
    let xdg = home.join("xdg-data");
    std::fs::create_dir_all(&xdg).expect("create xdg data home");

    // Fake running daemon at the macOS group container path.
    let group_daemon_root = home
        .join("Library")
        .join("Group Containers")
        .join(HARNESS_MONITOR_APP_GROUP_ID)
        .join("harness")
        .join("daemon");
    std::fs::create_dir_all(&group_daemon_root).expect("create group daemon root");
    let lock_path = group_daemon_root.join("daemon.lock");
    let lock_file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(&lock_path)
        .expect("open fake lock file");
    lock_file
        .try_lock_exclusive()
        .expect("hold exclusive flock on fake daemon lock");

    let mock_codex = create_mock_codex(home);

    let mut bridge = ManagedChild::spawn(
        Command::new(harness_binary())
            .args([
                "bridge",
                "start",
                "--capability",
                "codex",
                "--codex-port",
                "14520",
                "--codex-path",
            ])
            .arg(&mock_codex)
            .env("XDG_DATA_HOME", &xdg)
            .env("HOME", home)
            .env("HARNESS_HOST_HOME", home)
            .env("RUST_LOG", "harness=info")
            .env_remove("HARNESS_APP_GROUP_ID")
            .env_remove("HARNESS_DAEMON_DATA_HOME")
            .env_remove("HARNESS_SANDBOXED")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    )
    .expect("spawn bridge");

    let adopted_state_path = group_daemon_root.join("bridge.json");
    let xdg_state_path = xdg.join("harness").join("daemon").join("bridge.json");

    let bridge_result = wait_for_state_at(&adopted_state_path);

    // Regardless of outcome, clean up the bridge subprocess before panicking.
    let _ = bridge.kill();
    let _ = bridge.wait();
    // Release our flock last so the assertions see the state as it was
    // while the subprocess was scanning.
    drop(lock_file);

    bridge_result.expect("bridge state file did not appear at adopted root");

    assert!(
        !xdg_state_path.exists(),
        "bridge state must NOT land at XDG default ({}) when discovery adopts the group container",
        xdg_state_path.display()
    );
}

fn wait_for_state_at(state_path: &Path) -> Result<(), String> {
    let deadline = Instant::now() + BRIDGE_WAIT_TIMEOUT;
    loop {
        if state_path.exists() {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "bridge state file did not appear at {} within {:?}",
                state_path.display(),
                BRIDGE_WAIT_TIMEOUT
            ));
        }
        thread::sleep(BRIDGE_POLL_INTERVAL);
    }
}

fn create_mock_codex(base: &Path) -> PathBuf {
    let script = base.join("mock-codex");
    std::fs::write(
        &script,
        concat!(
            "#!/bin/sh\n",
            "if [ \"$1\" = \"--version\" ]; then\n",
            "  echo 'mock-codex 0.0.1'\n",
            "  exit 0\n",
            "fi\n",
            "sleep 300\n",
        ),
    )
    .expect("write mock codex");
    std::fs::set_permissions(
        &script,
        std::fs::Permissions::from(std::os::unix::fs::PermissionsExt::from_mode(0o755)),
    )
    .expect("chmod mock codex");
    script
}

fn harness_binary() -> PathBuf {
    assert_cmd::cargo::cargo_bin("harness")
}
