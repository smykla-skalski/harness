use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::thread;
use std::time::Instant;

use harness::daemon::bridge::BridgeState;

use super::super::helpers::ManagedChild;
use super::{BRIDGE_POLL_INTERVAL, BRIDGE_WAIT_TIMEOUT};

pub(super) fn wait_for_bridge_state(data_home: &Path) -> BridgeState {
    let state_path = data_home.join("harness/daemon/bridge.json");
    let deadline = Instant::now() + BRIDGE_WAIT_TIMEOUT;
    loop {
        if let Ok(data) = std::fs::read_to_string(&state_path)
            && let Ok(state) = serde_json::from_str::<BridgeState>(&data)
        {
            return state;
        }
        assert!(
            Instant::now() < deadline,
            "bridge state file did not appear at {}",
            state_path.display()
        );
        thread::sleep(BRIDGE_POLL_INTERVAL);
    }
}

pub(super) fn wait_for_bridge_exit(bridge: &mut ManagedChild) {
    let deadline = Instant::now() + BRIDGE_WAIT_TIMEOUT;
    loop {
        if bridge.try_wait().expect("poll bridge").is_some() {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "bridge process did not exit before timeout"
        );
        thread::sleep(BRIDGE_POLL_INTERVAL);
    }
}

pub(super) fn run_bridge(tmp: &tempfile::TempDir, args: &[&str]) -> Output {
    run_bridge_with_data_home(tmp.path(), args)
}

pub(super) fn run_bridge_with_data_home(data_home: &Path, args: &[&str]) -> Output {
    let host_home = ensure_host_home(data_home);
    Command::new(harness_binary())
        .args(args)
        .env("HARNESS_DAEMON_DATA_HOME", data_home)
        .env("XDG_DATA_HOME", data_home)
        .env("HARNESS_HOST_HOME", &host_home)
        .env("HOME", &host_home)
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_SANDBOXED")
        .output()
        .expect("run harness")
}

pub(super) fn ensure_host_home(data_home: &Path) -> PathBuf {
    let host_home = data_home.join("host-home");
    std::fs::create_dir_all(&host_home).expect("create host home");
    host_home
}

pub(super) fn harness_binary() -> PathBuf {
    assert_cmd::cargo::cargo_bin("harness")
}

pub(super) fn output_text(output: &Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    format!("stdout={stdout:?} stderr={stderr:?}")
}
