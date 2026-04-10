use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use harness::daemon::agent_tui_bridge::{AgentTuiBridgeState, AgentTuiBridgeStatusReport};
use tempfile::tempdir;

const BRIDGE_WAIT_TIMEOUT: Duration = Duration::from_secs(10);
const BRIDGE_POLL_INTERVAL: Duration = Duration::from_millis(100);

#[test]
fn agent_tui_bridge_status_reports_not_running_when_clean() {
    let tmp = tempdir().expect("tempdir");
    let output = run_bridge(&tmp, &["agent-tui-bridge", "status"]);
    assert!(output.status.success(), "status: {}", output_text(&output));

    let report: AgentTuiBridgeStatusReport =
        serde_json::from_slice(&output.stdout).expect("parse status");
    assert!(!report.running);
    assert!(report.socket_path.is_none());
    assert!(report.pid.is_none());
}

#[test]
fn agent_tui_bridge_status_plain_prints_not_running() {
    let tmp = tempdir().expect("tempdir");
    let output = run_bridge(&tmp, &["agent-tui-bridge", "status", "--plain"]);
    assert!(output.status.success(), "status: {}", output_text(&output));

    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("not running"), "unexpected: {text}");
}

#[test]
fn agent_tui_bridge_stop_is_idempotent_when_not_running() {
    let tmp = tempdir().expect("tempdir");
    let output = run_bridge(&tmp, &["agent-tui-bridge", "stop"]);
    assert!(output.status.success(), "stop: {}", output_text(&output));

    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("not running"), "unexpected: {text}");
}

#[test]
fn agent_tui_bridge_start_refuses_when_sandboxed() {
    let tmp = tempdir().expect("tempdir");
    let output = Command::new(harness_binary())
        .args(["agent-tui-bridge", "start"])
        .env("HARNESS_SANDBOXED", "1")
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .output()
        .expect("run harness");
    assert!(!output.status.success());

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("SANDBOX001") || stderr.contains("sandbox"),
        "expected sandbox error: {stderr}"
    );
}

#[test]
fn agent_tui_bridge_install_launch_agent_refuses_when_sandboxed() {
    let tmp = tempdir().expect("tempdir");
    let output = Command::new(harness_binary())
        .args(["agent-tui-bridge", "install-launch-agent"])
        .env("HARNESS_SANDBOXED", "1")
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .output()
        .expect("run harness");
    assert!(!output.status.success());

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("SANDBOX001") || stderr.contains("sandbox"),
        "expected sandbox error: {stderr}"
    );
}

#[test]
fn agent_tui_bridge_remove_launch_agent_refuses_when_sandboxed() {
    let tmp = tempdir().expect("tempdir");
    let output = Command::new(harness_binary())
        .args(["agent-tui-bridge", "remove-launch-agent"])
        .env("HARNESS_SANDBOXED", "1")
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .output()
        .expect("run harness");
    assert!(!output.status.success());

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("SANDBOX001") || stderr.contains("sandbox"),
        "expected sandbox error: {stderr}"
    );
}

#[test]
fn agent_tui_bridge_remove_launch_agent_is_idempotent() {
    let tmp = tempdir().expect("tempdir");
    let output = Command::new(harness_binary())
        .args(["agent-tui-bridge", "remove-launch-agent"])
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .env("HOME", tmp.path())
        .output()
        .expect("run harness");
    assert!(output.status.success(), "remove: {}", output_text(&output));

    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("not installed"), "unexpected output: {text}");
}

#[test]
fn agent_tui_bridge_start_publishes_state_and_stops_cleanly() {
    let tmp = tempdir().expect("tempdir");

    let mut bridge = Command::new(harness_binary())
        .args(["agent-tui-bridge", "start"])
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_SANDBOXED")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn bridge");

    let state = wait_for_bridge_state(tmp.path());
    assert!(state.pid > 0);
    assert!(
        state
            .socket_path
            .ends_with("harness/daemon/agent-tui-bridge.sock"),
        "unexpected socket path: {}",
        state.socket_path
    );

    let status_output = run_bridge(&tmp, &["agent-tui-bridge", "status"]);
    assert!(
        status_output.status.success(),
        "status: {}",
        output_text(&status_output)
    );
    let report: AgentTuiBridgeStatusReport =
        serde_json::from_slice(&status_output.stdout).expect("parse status");
    assert!(report.running);
    assert_eq!(report.pid, Some(state.pid));

    let stop_output = run_bridge(&tmp, &["agent-tui-bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "stop: {}",
        output_text(&stop_output)
    );

    let state_path = tmp.path().join("harness/daemon/agent-tui-bridge.json");
    assert!(!state_path.exists(), "state file should be cleaned up");

    let deadline = Instant::now() + BRIDGE_WAIT_TIMEOUT;
    loop {
        if bridge.try_wait().expect("poll bridge").is_some() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "bridge process did not exit after stop"
        );
        thread::sleep(BRIDGE_POLL_INTERVAL);
    }
}

fn wait_for_bridge_state(data_home: &std::path::Path) -> AgentTuiBridgeState {
    let state_path = data_home.join("harness/daemon/agent-tui-bridge.json");
    let deadline = Instant::now() + BRIDGE_WAIT_TIMEOUT;
    loop {
        if let Ok(data) = std::fs::read_to_string(&state_path) {
            if let Ok(state) = serde_json::from_str::<AgentTuiBridgeState>(&data) {
                return state;
            }
        }
        assert!(
            Instant::now() < deadline,
            "bridge state file did not appear at {}",
            state_path.display()
        );
        thread::sleep(BRIDGE_POLL_INTERVAL);
    }
}

fn run_bridge(tmp: &tempfile::TempDir, args: &[&str]) -> Output {
    Command::new(harness_binary())
        .args(args)
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_SANDBOXED")
        .output()
        .expect("run harness")
}

fn harness_binary() -> PathBuf {
    assert_cmd::cargo::cargo_bin("harness")
}

fn output_text(output: &Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    format!("stdout={stdout:?} stderr={stderr:?}")
}
