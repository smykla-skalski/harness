use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use harness::daemon::bridge::{BridgeState, BridgeStatusReport};
use tempfile::tempdir;

use super::helpers::ManagedChild;

mod readiness;
mod reconfigure;
mod support;

use self::support::*;

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
    let host_home = ensure_host_home(tmp.path());
    let output = Command::new(harness_binary())
        .args(["bridge", "start", "--capability", "codex"])
        .env("HARNESS_SANDBOXED", "1")
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .env("HARNESS_HOST_HOME", &host_home)
        .env("HOME", &host_home)
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
    let host_home = ensure_host_home(tmp.path());
    let mock_codex = create_mock_codex(tmp.path());
    let codex_port = unused_local_port();
    let codex_port_text = codex_port.to_string();
    let codex_endpoint = format!("ws://127.0.0.1:{codex_port}");

    let mut bridge = ManagedChild::spawn(
        Command::new(harness_binary())
            .args([
                "bridge",
                "start",
                "--capability",
                "codex",
                "--codex-port",
                &codex_port_text,
                "--codex-path",
            ])
            .arg(&mock_codex)
            .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
            .env("XDG_DATA_HOME", tmp.path())
            .env("HARNESS_HOST_HOME", &host_home)
            .env("HOME", &host_home)
            .env_remove("HARNESS_APP_GROUP_ID")
            .env_remove("HARNESS_SANDBOXED")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    )
    .expect("spawn bridge");

    let state = wait_for_bridge_state_with_capabilities(tmp.path(), &["codex"]);
    let codex = state.capabilities.get("codex").expect("codex capability");
    assert_eq!(codex.transport, "websocket");
    assert_eq!(codex.endpoint.as_deref(), Some(codex_endpoint.as_str()));
    assert_eq!(
        codex.metadata.get("port").map(String::as_str),
        Some(codex_port_text.as_str())
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
    let host_home = ensure_host_home(tmp.path());
    let mock_codex = create_mock_codex(tmp.path());
    let codex_port = unused_local_port();
    let codex_port_text = codex_port.to_string();

    let mut bridge = ManagedChild::spawn(
        Command::new(harness_binary())
            .args([
                "bridge",
                "start",
                "--codex-port",
                &codex_port_text,
                "--codex-path",
            ])
            .arg(&mock_codex)
            .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
            .env("XDG_DATA_HOME", tmp.path())
            .env("HARNESS_HOST_HOME", &host_home)
            .env("HOME", &host_home)
            .env_remove("HARNESS_APP_GROUP_ID")
            .env_remove("HARNESS_SANDBOXED")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    )
    .expect("spawn bridge");

    let state = wait_for_bridge_state_with_capabilities(tmp.path(), &["codex", "agent-tui"]);
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
fn bridge_install_launch_agent_refuses_when_sandboxed() {
    let tmp = tempdir().expect("tempdir");
    let host_home = ensure_host_home(tmp.path());
    let output = Command::new(harness_binary())
        .args(["bridge", "install-launch-agent", "--capability", "codex"])
        .env("HARNESS_SANDBOXED", "1")
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .env("HARNESS_HOST_HOME", &host_home)
        .env("HOME", &host_home)
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
    let host_home = ensure_host_home(tmp.path());
    let output = Command::new(harness_binary())
        .args(["bridge", "remove-launch-agent"])
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .env("HARNESS_HOST_HOME", &host_home)
        .env("HOME", &host_home)
        .output()
        .expect("run harness");
    assert!(output.status.success(), "remove: {}", output_text(&output));

    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("not installed"), "unexpected output: {text}");
}
