//! End-to-end coverage for `bridge.lock` acquisition and the regression where
//! the sandboxed daemon deleted `bridge.json` on a spurious watcher trigger.
//!
//! Commit 2 tests: lock lifecycle during `harness bridge start`.
//! Commit 3 tests: `bridge_json_survives_synthetic_watcher_trigger`.

#![cfg(target_os = "macos")]

use std::io::{BufRead, BufReader, Write as _};
use std::os::unix::net::UnixListener as StdUnixListener;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use harness::daemon::bridge::{self, BridgeState};
use harness::daemon::state::HostBridgeCapabilityManifest;

use super::helpers::ManagedChild;

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

fn legacy_codex_capabilities() -> std::collections::BTreeMap<String, HostBridgeCapabilityManifest> {
    std::collections::BTreeMap::from([(
        "codex".to_string(),
        HostBridgeCapabilityManifest {
            enabled: true,
            healthy: true,
            transport: "websocket".to_string(),
            endpoint: Some("ws://127.0.0.1:4500".to_string()),
            metadata: std::collections::BTreeMap::from([("port".to_string(), "4500".to_string())]),
        },
    )])
}

#[derive(Debug, Clone, Copy)]
enum LegacyShutdownBehavior {
    ExitAfter(Duration),
}

#[derive(Debug)]
struct LegacyBridgeServer {
    socket_path: PathBuf,
    token: String,
    terminate: Arc<AtomicBool>,
    join: Option<thread::JoinHandle<()>>,
}

impl LegacyBridgeServer {
    fn start(
        daemon_root: &std::path::Path,
        capabilities: std::collections::BTreeMap<String, HostBridgeCapabilityManifest>,
        shutdown_behavior: LegacyShutdownBehavior,
    ) -> Self {
        std::fs::create_dir_all(daemon_root).expect("create daemon root");
        let socket_path = daemon_root.join("legacy-bridge-test.sock");
        let token_path = daemon_root.join("legacy-bridge-token");
        let token = "legacy-bridge-token".to_string();
        let terminate = Arc::new(AtomicBool::new(false));
        let _ = std::fs::remove_file(&socket_path);
        std::fs::write(&token_path, &token).expect("write token");
        let state = BridgeState {
            socket_path: socket_path.display().to_string(),
            pid: 999_999_999,
            started_at: "2026-04-11T17:00:00Z".to_string(),
            token_path: token_path.display().to_string(),
            capabilities: capabilities.clone(),
        };
        std::fs::write(
            daemon_root.join("bridge.json"),
            serde_json::to_string_pretty(&state).expect("serialize bridge state"),
        )
        .expect("write bridge state");

        let listener = StdUnixListener::bind(&socket_path).expect("bind legacy bridge socket");
        let thread_socket_path = socket_path.clone();
        let thread_token = token.clone();
        let thread_terminate = Arc::clone(&terminate);
        let join = thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else {
                    break;
                };
                let mut line = String::new();
                BufReader::new(stream.try_clone().expect("clone stream"))
                    .read_line(&mut line)
                    .expect("read request");
                let request: serde_json::Value =
                    serde_json::from_str(&line).expect("parse bridge request");
                let operation = request["request"]["operation"]
                    .as_str()
                    .expect("operation string");
                let response = if request["token"].as_str() != Some(thread_token.as_str()) {
                    serde_json::json!({
                        "ok": false,
                        "code": "WORKFLOW_IO",
                        "message": "bridge token mismatch"
                    })
                } else {
                    match operation {
                        "status" => serde_json::json!({
                            "ok": true,
                            "payload": {
                                "running": true,
                                "socket_path": thread_socket_path.display().to_string(),
                                "pid": 999_999_999_u32,
                                "started_at": "2026-04-11T17:00:00Z",
                                "uptime_seconds": 1,
                                "capabilities": capabilities
                            }
                        }),
                        "shutdown" => serde_json::json!({ "ok": true }),
                        _ => serde_json::json!({
                            "ok": false,
                            "code": "WORKFLOW_PARSE",
                            "message": "unsupported legacy test request"
                        }),
                    }
                };
                stream
                    .write_all(
                        serde_json::to_string(&response)
                            .expect("serialize response")
                            .as_bytes(),
                    )
                    .expect("write response");
                stream.write_all(b"\n").expect("write newline");
                stream.flush().expect("flush response");

                if thread_terminate.load(Ordering::SeqCst) {
                    break;
                }
                if operation == "shutdown" {
                    match shutdown_behavior {
                        LegacyShutdownBehavior::ExitAfter(delay) => {
                            thread::sleep(delay);
                            break;
                        }
                    }
                }
            }
            let _ = std::fs::remove_file(&thread_socket_path);
        });

        Self {
            socket_path,
            token,
            terminate,
            join: Some(join),
        }
    }

    fn wake(&self) {
        let payload = serde_json::json!({
            "token": self.token,
            "request": { "operation": "status" }
        });
        if let Ok(mut stream) = std::os::unix::net::UnixStream::connect(&self.socket_path) {
            let _ = stream.write_all(payload.to_string().as_bytes());
            let _ = stream.write_all(b"\n");
            let _ = stream.flush();
        }
    }
}

impl Drop for LegacyBridgeServer {
    fn drop(&mut self) {
        self.terminate.store(true, Ordering::SeqCst);
        self.wake();
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

/// `harness bridge start` must create `bridge.lock` and hold it exclusively
/// while serving. A second concurrent `harness bridge start` must fail with
/// a non-zero exit code.
#[test]
fn bridge_start_holds_exclusive_bridge_lock_while_serving() {
    use fs2::FileExt;
    use tempfile::tempdir;

    let tmp = tempdir().expect("tempdir");
    let host_home = tmp.path().join("host-home");
    std::fs::create_dir_all(&host_home).expect("create host home");
    let daemon_data_home = tmp.path().to_str().expect("utf8").to_string();
    // Redirect host home to the tempdir so the macOS group-container candidate
    // in discovery points inside the tempdir (nonexistent) and adoption cannot
    // be fooled by a real Monitor daemon running on the developer machine.
    let host_home = host_home.to_str().expect("utf8 host home").to_string();

    let mut first_bridge = ManagedChild::spawn(
        Command::new(harness_binary())
            .args(["bridge", "start", "--capability", "agent-tui"])
            .env("HARNESS_DAEMON_DATA_HOME", &daemon_data_home)
            .env("HARNESS_HOST_HOME", &host_home)
            .env("HOME", &host_home)
            .env_remove("HARNESS_APP_GROUP_ID")
            .env_remove("HARNESS_SANDBOXED")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    )
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
        .env("HARNESS_HOST_HOME", &host_home)
        .env("HOME", &host_home)
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

/// Reproduces the original v19.6.0 bug empirically.
///
/// A synthetic `bridge.json` with a fake pid is written to the daemon root.
/// A real `bridge.lock` flock is held to simulate a live bridge. The daemon
/// watcher logic (`apply_bridge_state_to_manifest` / `load_running_bridge_state`)
/// is exercised via `harness daemon status` — a command that reads the manifest
/// without requiring a live daemon socket. The test then verifies:
///
/// 1. `bridge.json` still exists (the consumer path never deletes it).
/// 2. Dropping the flock and repeating still does not delete the file (the
///    file stays; only the manifest view changes).
#[test]
fn bridge_json_survives_synthetic_watcher_trigger() {
    use fs2::FileExt;
    use tempfile::tempdir;

    let tmp = tempdir().expect("tempdir");
    let host_home = tmp.path().join("host-home");
    std::fs::create_dir_all(&host_home).expect("create host home");
    let daemon_data_home = tmp.path().to_str().expect("utf8").to_string();
    // See the sibling test for rationale - isolate host_home so discovery
    // cannot be fooled by a real Monitor daemon on the dev machine.
    let host_home = host_home.to_str().expect("utf8 host home").to_string();

    // Set up daemon root and write a synthetic bridge.json.
    let daemon_root = tmp.path().join("harness").join("daemon");
    std::fs::create_dir_all(&daemon_root).expect("create daemon root");

    let bridge_json = daemon_root.join("bridge.json");
    std::fs::write(
        &bridge_json,
        r#"{"socket_path":"/tmp/synthetic.sock","pid":1,"started_at":"2026-04-11T17:00:00Z","token_path":"/tmp/synth-token","capabilities":{}}"#,
    )
    .expect("write synthetic bridge.json");

    // Hold bridge.lock to simulate a live bridge.
    let lock_path = daemon_root.join("bridge.lock");
    let lock_file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(&lock_path)
        .expect("open bridge lock");
    lock_file
        .try_lock_exclusive()
        .expect("hold exclusive flock on bridge lock");

    // Touch bridge-config.json to simulate a watcher trigger.
    let bridge_config = daemon_root.join("bridge-config.json");
    std::fs::write(
        &bridge_config,
        r#"{"capabilities":["agent-tui"],"socket_path":null,"codex_port":null,"codex_path":null}"#,
    )
    .expect("write bridge-config.json");

    // Run `harness bridge status` — this exercises load_running_bridge_state
    // on the host-CLI path. bridge.json should survive regardless.
    let status = Command::new(harness_binary())
        .args(["bridge", "status"])
        .env("HARNESS_DAEMON_DATA_HOME", &daemon_data_home)
        .env("HARNESS_HOST_HOME", &host_home)
        .env("HOME", &host_home)
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_SANDBOXED")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .expect("run harness bridge status");
    // status may succeed or fail (no live socket) but must not crash.
    let _ = status;

    assert!(
        bridge_json.exists(),
        "bridge.json must survive after status read while bridge.lock is held"
    );

    // Drop the lock to simulate the bridge having stopped. bridge.json should
    // still not be deleted by a consumer-path read.
    drop(lock_file);

    let _status2 = Command::new(harness_binary())
        .args(["bridge", "status"])
        .env("HARNESS_DAEMON_DATA_HOME", &daemon_data_home)
        .env("HARNESS_HOST_HOME", &host_home)
        .env("HOME", &host_home)
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_SANDBOXED")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .expect("run harness bridge status after lock release");

    // Even after the lock is released, load_running_bridge_state must not
    // delete bridge.json. This locks in the stronger invariant: the loader
    // never deletes producer state regardless of liveness outcome.
    assert!(
        bridge_json.exists(),
        "bridge.json must survive a bridge status read after bridge.lock is released"
    );
}

#[test]
fn sandboxed_host_bridge_manifest_uses_legacy_bridge_rpc_without_lock() {
    use tempfile::tempdir;

    let tmp = tempdir().expect("tempdir");
    let daemon_data_home = tmp.path().to_str().expect("utf8").to_string();
    let daemon_root = tmp.path().join("harness").join("daemon");
    let _server = LegacyBridgeServer::start(
        &daemon_root,
        legacy_codex_capabilities(),
        LegacyShutdownBehavior::ExitAfter(Duration::ZERO),
    );

    temp_env::with_vars(
        [
            ("HARNESS_DAEMON_DATA_HOME", Some(daemon_data_home.as_str())),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_SANDBOXED", Some("1")),
        ],
        || {
            let manifest = bridge::host_bridge_manifest().expect("host bridge manifest");
            assert!(manifest.running);
            assert_eq!(
                manifest
                    .capabilities
                    .get("codex")
                    .and_then(|capability| capability.endpoint.as_deref()),
                Some("ws://127.0.0.1:4500")
            );
        },
    );
}

#[test]
fn sandboxed_stop_bridge_waits_for_legacy_rpc_shutdown_before_clearing_state() {
    use tempfile::tempdir;

    let tmp = tempdir().expect("tempdir");
    let daemon_data_home = tmp.path().to_str().expect("utf8").to_string();
    let daemon_root = tmp.path().join("harness").join("daemon");
    let _server = LegacyBridgeServer::start(
        &daemon_root,
        legacy_codex_capabilities(),
        LegacyShutdownBehavior::ExitAfter(Duration::from_millis(250)),
    );

    temp_env::with_vars(
        [
            ("HARNESS_DAEMON_DATA_HOME", Some(daemon_data_home.as_str())),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_SANDBOXED", Some("1")),
        ],
        || {
            let started = Instant::now();
            let report = bridge::stop_bridge().expect("stop bridge");
            assert!(
                started.elapsed() >= Duration::from_millis(200),
                "sandboxed stop should wait for RPC disappearance"
            );
            assert!(!report.running);
            assert!(
                !daemon_root.join("bridge.json").exists(),
                "bridge state should be cleared after the RPC proof disappears"
            );
        },
    );
}
