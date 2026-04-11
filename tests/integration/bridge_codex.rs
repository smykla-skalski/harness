use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use harness::daemon::bridge::{BridgeState, BridgeStatusReport};
use tempfile::tempdir;

const BRIDGE_WAIT_TIMEOUT: Duration = Duration::from_secs(10);
const BRIDGE_POLL_INTERVAL: Duration = Duration::from_millis(100);

#[test]
fn bridge_status_reports_not_running_when_clean() {
    let tmp = tempdir().expect("tempdir");
    let output = run_bridge(&tmp, &["bridge", "status"]);
    assert!(output.status.success(), "status: {}", output_text(&output));

    let report: BridgeStatusReport = serde_json::from_slice(&output.stdout).expect("parse status");
    assert!(!report.running);
    assert!(report.socket_path.is_none());
    assert!(report.capabilities.is_empty());
}

#[test]
fn bridge_status_plain_prints_not_running() {
    let tmp = tempdir().expect("tempdir");
    let output = run_bridge(&tmp, &["bridge", "status", "--plain"]);
    assert!(output.status.success(), "status: {}", output_text(&output));

    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("not running"), "unexpected: {text}");
}

#[test]
fn bridge_stop_is_idempotent_when_not_running() {
    let tmp = tempdir().expect("tempdir");
    let output = run_bridge(&tmp, &["bridge", "stop"]);
    assert!(output.status.success(), "stop: {}", output_text(&output));

    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("not running"), "unexpected: {text}");
}

#[test]
fn bridge_start_refuses_when_sandboxed() {
    let tmp = tempdir().expect("tempdir");
    let output = Command::new(harness_binary())
        .args(["bridge", "start", "--capability", "codex"])
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
fn bridge_start_with_mock_codex_publishes_codex_capability() {
    let tmp = tempdir().expect("tempdir");
    let mock_codex = create_mock_codex(tmp.path());

    let mut bridge = Command::new(harness_binary())
        .args([
            "bridge",
            "start",
            "--capability",
            "codex",
            "--codex-port",
            "14500",
            "--codex-path",
        ])
        .arg(&mock_codex)
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .env("HARNESS_HOST_HOME", tmp.path())
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_SANDBOXED")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn bridge");

    let state = wait_for_bridge_state(tmp.path());
    let codex = state.capabilities.get("codex").expect("codex capability");
    assert_eq!(codex.transport, "websocket");
    assert_eq!(codex.endpoint.as_deref(), Some("ws://127.0.0.1:14500"));
    assert_eq!(
        codex.metadata.get("port").map(String::as_str),
        Some("14500")
    );

    let status_output = run_bridge(&tmp, &["bridge", "status"]);
    assert!(
        status_output.status.success(),
        "status: {}",
        output_text(&status_output)
    );
    let report: BridgeStatusReport = serde_json::from_slice(&status_output.stdout).expect("parse");
    assert!(report.running);
    assert!(report.capabilities.contains_key("codex"));
    assert!(!report.capabilities.contains_key("agent-tui"));

    let stop_output = run_bridge(&tmp, &["bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "stop: {}",
        output_text(&stop_output)
    );

    let state_path = tmp.path().join("harness/daemon/bridge.json");
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

#[test]
fn bridge_start_without_capability_flag_enables_all_compiled_capabilities() {
    let tmp = tempdir().expect("tempdir");
    let mock_codex = create_mock_codex(tmp.path());

    let mut bridge = Command::new(harness_binary())
        .args(["bridge", "start", "--codex-port", "14501", "--codex-path"])
        .arg(&mock_codex)
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .env("HARNESS_HOST_HOME", tmp.path())
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_SANDBOXED")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn bridge");

    let state = wait_for_bridge_state(tmp.path());
    assert!(state.capabilities.contains_key("codex"));
    assert!(state.capabilities.contains_key("agent-tui"));

    let status_output = run_bridge(&tmp, &["bridge", "status"]);
    assert!(
        status_output.status.success(),
        "status: {}",
        output_text(&status_output)
    );
    let report: BridgeStatusReport = serde_json::from_slice(&status_output.stdout).expect("parse");
    assert!(report.running);
    assert!(report.capabilities.contains_key("codex"));
    assert!(report.capabilities.contains_key("agent-tui"));

    let stop_output = run_bridge(&tmp, &["bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "stop: {}",
        output_text(&stop_output)
    );

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

#[test]
fn bridge_reconfigure_enables_codex_without_restarting_bridge() {
    let tmp = tempdir().expect("tempdir");
    let mock_codex = create_mock_codex(tmp.path());

    let mut bridge = Command::new(harness_binary())
        .args([
            "bridge",
            "start",
            "--capability",
            "agent-tui",
            "--codex-port",
            "14502",
            "--codex-path",
        ])
        .arg(&mock_codex)
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .env("HARNESS_HOST_HOME", tmp.path())
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_SANDBOXED")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn bridge");

    let initial_state = wait_for_bridge_state(tmp.path());
    let output = run_bridge(
        &tmp,
        &["bridge", "reconfigure", "--enable", "codex", "--json"],
    );
    assert!(
        output.status.success(),
        "reconfigure: {}",
        output_text(&output)
    );

    let report: BridgeStatusReport = serde_json::from_slice(&output.stdout).expect("parse");
    assert_eq!(report.pid, Some(initial_state.pid));
    assert!(report.capabilities.contains_key("agent-tui"));
    let codex = report.capabilities.get("codex").expect("codex capability");
    assert_eq!(codex.endpoint.as_deref(), Some("ws://127.0.0.1:14502"));
    assert_eq!(
        codex.metadata.get("port").map(String::as_str),
        Some("14502")
    );

    let stop_output = run_bridge(&tmp, &["bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "stop: {}",
        output_text(&stop_output)
    );
    wait_for_bridge_exit(&mut bridge);
}

#[test]
fn bridge_reconfigure_persists_capabilities_across_restart() {
    let tmp = tempdir().expect("tempdir");
    let mock_codex = create_mock_codex(tmp.path());

    let mut bridge = Command::new(harness_binary())
        .args(["bridge", "start", "--codex-port", "14503", "--codex-path"])
        .arg(&mock_codex)
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .env("HARNESS_HOST_HOME", tmp.path())
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_SANDBOXED")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn bridge");

    let _initial_state = wait_for_bridge_state(tmp.path());
    let output = run_bridge(
        &tmp,
        &["bridge", "reconfigure", "--disable", "codex", "--json"],
    );
    assert!(
        output.status.success(),
        "reconfigure: {}",
        output_text(&output)
    );
    let report: BridgeStatusReport = serde_json::from_slice(&output.stdout).expect("parse");
    assert!(report.capabilities.contains_key("agent-tui"));
    assert!(!report.capabilities.contains_key("codex"));

    let stop_output = run_bridge(&tmp, &["bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "stop: {}",
        output_text(&stop_output)
    );
    wait_for_bridge_exit(&mut bridge);

    let mut restarted = Command::new(harness_binary())
        .args(["bridge", "start"])
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .env("HARNESS_HOST_HOME", tmp.path())
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_SANDBOXED")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn restarted bridge");

    let restarted_state = wait_for_bridge_state(tmp.path());
    assert!(restarted_state.capabilities.contains_key("agent-tui"));
    assert!(!restarted_state.capabilities.contains_key("codex"));

    let stop_output = run_bridge(&tmp, &["bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "cleanup stop: {}",
        output_text(&stop_output)
    );
    wait_for_bridge_exit(&mut restarted);
}

#[test]
fn bridge_install_launch_agent_refuses_when_sandboxed() {
    let tmp = tempdir().expect("tempdir");
    let output = Command::new(harness_binary())
        .args(["bridge", "install-launch-agent", "--capability", "codex"])
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
fn bridge_remove_launch_agent_is_idempotent() {
    let tmp = tempdir().expect("tempdir");
    let output = Command::new(harness_binary())
        .args(["bridge", "remove-launch-agent"])
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .env("HOME", tmp.path())
        .output()
        .expect("run harness");
    assert!(output.status.success(), "remove: {}", output_text(&output));

    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("not installed"), "unexpected output: {text}");
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

fn wait_for_bridge_state(data_home: &Path) -> BridgeState {
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

fn wait_for_bridge_exit(bridge: &mut std::process::Child) {
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

fn run_bridge(tmp: &tempfile::TempDir, args: &[&str]) -> Output {
    Command::new(harness_binary())
        .args(args)
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .env("HARNESS_HOST_HOME", tmp.path())
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
