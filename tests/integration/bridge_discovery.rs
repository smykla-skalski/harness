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

use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use fs2::FileExt;
use harness::daemon::bridge::BridgeState;
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
    let codex_port = unused_local_port();
    let codex_port_text = codex_port.to_string();

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
    let adopted_state = std::fs::read_to_string(&adopted_state_path)
        .ok()
        .map(|raw| serde_json::from_str::<BridgeState>(&raw).expect("parse adopted bridge state"));

    // Shut the bridge down through its own control plane so the adopted
    // short socket path is unlinked instead of being stranded under `/tmp`.
    let stop_output = run_bridge(home, &xdg, &["bridge", "stop"]);
    let stop_text = output_text(&stop_output);
    let stop_ok = stop_output.status.success();
    let bridge_exit = wait_for_bridge_exit(&mut bridge);
    // Release our flock last so the assertions see the state as it was
    // while the subprocess was scanning.
    drop(lock_file);

    bridge_result.expect("bridge state file did not appear at adopted root");
    assert!(stop_ok, "bridge stop failed: {stop_text}");
    bridge_exit.expect("bridge process did not exit after stop");

    assert!(
        !xdg_state_path.exists(),
        "bridge state must NOT land at XDG default ({}) when discovery adopts the group container",
        xdg_state_path.display()
    );
    if let Some(state) = adopted_state {
        assert!(
            !PathBuf::from(&state.socket_path).exists(),
            "bridge socket should be removed after stop: {}",
            state.socket_path
        );
    }
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
        r#"#!/bin/sh
if [ "$1" = "--version" ]; then
  echo 'mock-codex 0.0.1'
  exit 0
fi

exec python3 - "$@" <<'PY'
import socket
import sys

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

fn run_bridge(home: &Path, xdg: &Path, args: &[&str]) -> Output {
    Command::new(harness_binary())
        .args(args)
        .env("XDG_DATA_HOME", xdg)
        .env("HOME", home)
        .env("HARNESS_HOST_HOME", home)
        .env("RUST_LOG", "harness=info")
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_DAEMON_DATA_HOME")
        .env_remove("HARNESS_SANDBOXED")
        .output()
        .expect("run harness")
}

fn harness_binary() -> PathBuf {
    assert_cmd::cargo::cargo_bin("harness")
}

fn unused_local_port() -> u16 {
    TcpListener::bind(("127.0.0.1", 0))
        .expect("bind local port")
        .local_addr()
        .expect("read local addr")
        .port()
}

fn wait_for_bridge_exit(bridge: &mut ManagedChild) -> Result<(), String> {
    let deadline = Instant::now() + BRIDGE_WAIT_TIMEOUT;
    loop {
        if bridge
            .try_wait()
            .map_err(|error| error.to_string())?
            .is_some()
        {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err("bridge process did not exit before timeout".to_string());
        }
        thread::sleep(BRIDGE_POLL_INTERVAL);
    }
}

fn output_text(output: &Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if stderr.trim().is_empty() {
        stdout.into_owned()
    } else if stdout.trim().is_empty() {
        stderr.into_owned()
    } else {
        format!("{stdout}\n{stderr}")
    }
}
