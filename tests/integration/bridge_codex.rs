use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use harness::daemon::bridge::{BridgeState, BridgeStatusReport};
use tempfile::tempdir;

use super::helpers::ManagedChild;

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
fn bridge_start_waits_for_codex_readiness_before_publishing_state() {
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
            .env("MOCK_CODEX_READY_DELAY_MS", "1500")
            .env_remove("HARNESS_APP_GROUP_ID")
            .env_remove("HARNESS_SANDBOXED")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    )
    .expect("spawn bridge");

    thread::sleep(Duration::from_millis(250));
    let state_path = tmp.path().join("harness/daemon/bridge.json");
    assert!(
        !state_path.exists(),
        "bridge state should not publish before codex readiness"
    );

    let state = wait_for_bridge_state_with_capabilities(tmp.path(), &["codex"]);
    let codex = state.capabilities.get("codex").expect("codex capability");
    assert_eq!(codex.endpoint.as_deref(), Some(codex_endpoint.as_str()));

    let events = read_daemon_events(tmp.path());
    assert!(
        events.contains(&format!(
            "codex host bridge readiness still pending on ws://127.0.0.1:{codex_port}"
        )),
        "expected readiness warning event, got: {events}"
    );
    assert!(
        events.contains(&format!(
            "codex host bridge ready on ws://127.0.0.1:{codex_port}"
        )),
        "expected readiness success event, got: {events}"
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
fn bridge_start_records_error_when_codex_exits_before_readiness() {
    let tmp = tempdir().expect("tempdir");
    let host_home = ensure_host_home(tmp.path());
    let mock_codex = create_mock_codex(tmp.path());
    let codex_port = unused_local_port();
    let codex_port_text = codex_port.to_string();

    let output = Command::new(harness_binary())
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
        .env("MOCK_CODEX_EXIT_BEFORE_READY", "1")
        .env("MOCK_CODEX_EXIT_STATUS", "23")
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_SANDBOXED")
        .output()
        .expect("run bridge");

    assert!(!output.status.success(), "bridge unexpectedly succeeded");
    assert!(
        !tmp.path().join("harness/daemon/bridge.json").exists(),
        "bridge state should not persist failed codex readiness"
    );

    let events = read_daemon_events(tmp.path());
    assert!(
        events.contains(&format!(
            "starting codex host bridge on ws://127.0.0.1:{codex_port}"
        )),
        "expected startup event, got: {events}"
    );
    assert!(
        events.contains(&format!(
            "codex host bridge failed before readiness on ws://127.0.0.1:{codex_port}"
        )),
        "expected readiness error event, got: {events}"
    );
}

#[test]
fn bridge_start_fails_when_codex_port_is_already_bound() {
    let tmp = tempdir().expect("tempdir");
    let host_home = ensure_host_home(tmp.path());
    let mock_codex = create_mock_codex(tmp.path());
    let occupied_listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind occupied codex port");
    let codex_port = occupied_listener
        .local_addr()
        .expect("read occupied listener addr")
        .port();
    let codex_port_text = codex_port.to_string();

    let output = Command::new(harness_binary())
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
        .output()
        .expect("run bridge");

    assert!(
        !output.status.success(),
        "bridge unexpectedly succeeded: {}",
        output_text(&output)
    );
    assert!(
        !tmp.path().join("harness/daemon/bridge.json").exists(),
        "bridge state should not persist when the codex port is already bound"
    );

    let events = read_daemon_events(tmp.path());
    assert!(
        events.contains(&format!(
            "codex host bridge failed before readiness on ws://127.0.0.1:{codex_port}: 127.0.0.1:{codex_port} is unavailable"
        )),
        "expected occupied-port error event, got: {events}"
    );
}

#[test]
fn bridge_start_records_error_when_codex_readiness_times_out() {
    let tmp = tempdir().expect("tempdir");
    let host_home = ensure_host_home(tmp.path());
    let mock_codex = create_mock_codex(tmp.path());
    let codex_port = unused_local_port();
    let codex_port_text = codex_port.to_string();

    let output = Command::new(harness_binary())
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
        .env("MOCK_CODEX_READY_DELAY_MS", "11000")
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_SANDBOXED")
        .output()
        .expect("run bridge");

    assert!(!output.status.success(), "bridge unexpectedly succeeded");
    assert!(
        !tmp.path().join("harness/daemon/bridge.json").exists(),
        "bridge state should not persist timed out codex readiness"
    );

    let events = read_daemon_events(tmp.path());
    assert!(
        events.contains(&format!(
            "codex host bridge readiness still pending on ws://127.0.0.1:{codex_port}"
        )),
        "expected readiness warning event, got: {events}"
    );
    assert!(
        events.contains(&format!(
            "codex host bridge readiness timed out on ws://127.0.0.1:{codex_port}"
        )),
        "expected readiness timeout event, got: {events}"
    );
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
fn bridge_reconfigure_enables_codex_without_restarting_bridge() {
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
                "agent-tui",
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

    let initial_state = wait_for_bridge_state_with_capabilities(tmp.path(), &["agent-tui"]);
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
    assert_eq!(codex.endpoint.as_deref(), Some(codex_endpoint.as_str()));
    assert_eq!(
        codex.metadata.get("port").map(String::as_str),
        Some(codex_port_text.as_str())
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

    let _initial_state =
        wait_for_bridge_state_with_capabilities(tmp.path(), &["codex", "agent-tui"]);
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

    let mut restarted = ManagedChild::spawn(
        Command::new(harness_binary())
            .args(["bridge", "start"])
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
    .expect("spawn restarted bridge");

    let restarted_state = wait_for_bridge_state_with_capabilities(tmp.path(), &["agent-tui"]);
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

fn create_mock_codex(base: &Path) -> PathBuf {
    let script = base.join("mock-codex");
    std::fs::write(
        &script,
        r#"#!/bin/sh
if [ "$1" = "--version" ]; then
  echo 'mock-codex 0.0.1'
  exit 0
fi

exec python3 - "$@" <<'PY'
import os
import socket
import sys
import time

args = sys.argv[1:]
if len(args) < 3 or args[0] != "app-server" or args[1] != "--listen":
    print(f"unexpected args: {args}", file=sys.stderr)
    sys.exit(2)

listen = args[2]
if not listen.startswith("ws://"):
    print(f"unexpected listen address: {listen}", file=sys.stderr)
    sys.exit(3)

address = listen[len("ws://"):]
host, port = address.rsplit(":", 1)
port = int(port)
delay_ms = int(os.environ.get("MOCK_CODEX_READY_DELAY_MS", "0"))
exit_before_ready = os.environ.get("MOCK_CODEX_EXIT_BEFORE_READY") == "1"
exit_status = int(os.environ.get("MOCK_CODEX_EXIT_STATUS", "17"))

if delay_ms > 0:
    time.sleep(delay_ms / 1000.0)

if exit_before_ready:
    sys.exit(exit_status)

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind((host, port))
server.listen()

while True:
    conn, _ = server.accept()
    request = b""
    while b"\r\n\r\n" not in request:
        chunk = conn.recv(4096)
        if not chunk:
            break
        request += chunk

    if request.startswith(b"GET /readyz ") or request.startswith(b"GET /healthz "):
        body = b"ok\n"
        response = (
            b"HTTP/1.1 200 OK\r\n"
            + f"Content-Length: {len(body)}\r\n".encode()
            + b"Connection: close\r\n\r\n"
            + body
        )
    else:
        body = b"missing\n"
        response = (
            b"HTTP/1.1 404 Not Found\r\n"
            + f"Content-Length: {len(body)}\r\n".encode()
            + b"Connection: close\r\n\r\n"
            + body
        )
    conn.sendall(response)
    conn.close()
PY
"#,
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

fn read_daemon_events(data_home: &Path) -> String {
    std::fs::read_to_string(data_home.join("harness/daemon/events.jsonl")).unwrap_or_default()
}

fn wait_for_bridge_state_with_capabilities(data_home: &Path, capabilities: &[&str]) -> BridgeState {
    let deadline = Instant::now() + BRIDGE_WAIT_TIMEOUT;
    loop {
        let state = wait_for_bridge_state(data_home);
        if capabilities
            .iter()
            .all(|capability| state.capabilities.contains_key(*capability))
        {
            return state;
        }
        assert!(
            Instant::now() < deadline,
            "bridge state did not expose capabilities {:?} before timeout; actual capabilities: {:?}",
            capabilities,
            state.capabilities.keys().collect::<Vec<_>>()
        );
        thread::sleep(BRIDGE_POLL_INTERVAL);
    }
}

fn wait_for_bridge_exit(bridge: &mut ManagedChild) {
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
    let host_home = ensure_host_home(tmp.path());
    Command::new(harness_binary())
        .args(args)
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .env("HARNESS_HOST_HOME", &host_home)
        .env("HOME", &host_home)
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_SANDBOXED")
        .output()
        .expect("run harness")
}

fn ensure_host_home(data_home: &Path) -> PathBuf {
    let host_home = data_home.join("host-home");
    std::fs::create_dir_all(&host_home).expect("create host home");
    host_home
}

fn unused_local_port() -> u16 {
    TcpListener::bind(("127.0.0.1", 0))
        .expect("bind local port")
        .local_addr()
        .expect("read local addr")
        .port()
}

fn harness_binary() -> PathBuf {
    assert_cmd::cargo::cargo_bin("harness")
}

fn output_text(output: &Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    format!("stdout={stdout:?} stderr={stderr:?}")
}
