use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use harness::daemon::codex_bridge::{CodexBridgeState, CodexBridgeStatusReport};
use tempfile::tempdir;

const BRIDGE_WAIT_TIMEOUT: Duration = Duration::from_secs(10);
const BRIDGE_POLL_INTERVAL: Duration = Duration::from_millis(100);

#[test]
fn codex_bridge_status_reports_not_running_when_clean() {
    let tmp = tempdir().expect("tempdir");
    let output = run_bridge(&tmp, &["codex-bridge", "status"]);
    assert!(output.status.success(), "status: {}", output_text(&output));

    let report: CodexBridgeStatusReport =
        serde_json::from_slice(&output.stdout).expect("parse status");
    assert!(!report.running);
    assert!(report.endpoint.is_none());
    assert!(report.pid.is_none());
}

#[test]
fn codex_bridge_status_plain_prints_not_running() {
    let tmp = tempdir().expect("tempdir");
    let output = run_bridge(&tmp, &["codex-bridge", "status", "--plain"]);
    assert!(output.status.success(), "status: {}", output_text(&output));

    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("not running"), "unexpected: {text}");
}

#[test]
fn codex_bridge_stop_is_idempotent_when_not_running() {
    let tmp = tempdir().expect("tempdir");
    let output = run_bridge(&tmp, &["codex-bridge", "stop"]);
    assert!(output.status.success(), "stop: {}", output_text(&output));

    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("not running"), "unexpected: {text}");
}

#[test]
fn codex_bridge_start_refuses_when_sandboxed() {
    let tmp = tempdir().expect("tempdir");
    let output = Command::new(harness_binary())
        .args(["codex-bridge", "start"])
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
fn codex_bridge_start_with_mock_codex_publishes_state() {
    let tmp = tempdir().expect("tempdir");
    let mock_codex = create_mock_codex(tmp.path());

    let mut bridge = Command::new(harness_binary())
        .args(["codex-bridge", "start", "--port", "14500", "--codex-path"])
        .arg(&mock_codex)
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
    assert_eq!(state.port, 14500);
    assert!(state.endpoint.contains("14500"));
    assert!(state.pid > 0);

    let status_output = run_bridge(&tmp, &["codex-bridge", "status"]);
    assert!(
        status_output.status.success(),
        "status: {}",
        output_text(&status_output)
    );
    let report: CodexBridgeStatusReport =
        serde_json::from_slice(&status_output.stdout).expect("parse status");
    assert!(report.running);
    assert_eq!(report.port, Some(14500));

    let stop_output = run_bridge(&tmp, &["codex-bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "stop: {}",
        output_text(&stop_output)
    );

    let endpoint_path = tmp.path().join("harness/daemon/codex-endpoint.json");
    assert!(!endpoint_path.exists(), "state file should be cleaned up");

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
fn codex_bridge_install_launch_agent_refuses_when_sandboxed() {
    let tmp = tempdir().expect("tempdir");
    let output = Command::new(harness_binary())
        .args(["codex-bridge", "install-launch-agent"])
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
fn codex_bridge_remove_launch_agent_is_idempotent() {
    let tmp = tempdir().expect("tempdir");
    let output = Command::new(harness_binary())
        .args(["codex-bridge", "remove-launch-agent"])
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

fn wait_for_bridge_state(data_home: &Path) -> CodexBridgeState {
    let endpoint_path = data_home.join("harness/daemon/codex-endpoint.json");
    let deadline = Instant::now() + BRIDGE_WAIT_TIMEOUT;
    loop {
        if let Ok(data) = std::fs::read_to_string(&endpoint_path) {
            if let Ok(state) = serde_json::from_str::<CodexBridgeState>(&data) {
                return state;
            }
        }
        assert!(
            Instant::now() < deadline,
            "bridge state file did not appear at {}",
            endpoint_path.display()
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
