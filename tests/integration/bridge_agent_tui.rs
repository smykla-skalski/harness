use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use harness::daemon::agent_tui::{AgentTuiLaunchProfile, AgentTuiSize};
use harness::daemon::bridge::{AgentTuiStartSpec, BridgeClient, BridgeState, BridgeStatusReport};
use tempfile::tempdir;

const BRIDGE_WAIT_TIMEOUT: Duration = Duration::from_secs(10);
const BRIDGE_POLL_INTERVAL: Duration = Duration::from_millis(100);

#[test]
fn bridge_status_reports_not_running_when_clean() {
    let tmp = tempdir().expect("tempdir");
    let output = run_bridge(&tmp, &["bridge", "status"]);
    assert!(output.status.success(), "status: {}", output_text(&output));

    let report: BridgeStatusReport = serde_json::from_slice(&output.stdout).expect("parse");
    assert!(!report.running);
    assert!(report.socket_path.is_none());
}

#[test]
fn bridge_start_refuses_when_sandboxed() {
    let tmp = tempdir().expect("tempdir");
    let output = Command::new(harness_binary())
        .args(["bridge", "start", "--capability", "agent-tui"])
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
fn bridge_start_publishes_agent_tui_capability_and_stops_cleanly() {
    let tmp = tempdir().expect("tempdir");

    let mut bridge = Command::new(harness_binary())
        .args(["bridge", "start", "--capability", "agent-tui"])
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
        state.socket_path.ends_with("harness/daemon/bridge.sock"),
        "unexpected socket path: {}",
        state.socket_path
    );
    let capability = state
        .capabilities
        .get("agent-tui")
        .expect("agent-tui capability");
    assert_eq!(capability.transport, "unix");
    assert_eq!(
        capability
            .metadata
            .get("active_sessions")
            .map(String::as_str),
        Some("0")
    );

    let status_output = run_bridge(&tmp, &["bridge", "status"]);
    assert!(
        status_output.status.success(),
        "status: {}",
        output_text(&status_output)
    );
    let report: BridgeStatusReport = serde_json::from_slice(&status_output.stdout).expect("parse");
    assert!(report.running);
    assert!(report.capabilities.contains_key("agent-tui"));
    assert!(!report.capabilities.contains_key("codex"));

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
fn bridge_start_daemon_uses_short_socket_path_for_long_data_home() {
    let tmp = tempdir().expect("tempdir");
    let data_home = tmp.path().join(
        "deep/nesting/that/makes/the/default/daemon/socket/path/too/long/for/macos/unix/domain/sockets",
    );
    std::fs::create_dir_all(&data_home).expect("create data home");

    let output = run_bridge_with_data_home(
        &data_home,
        &["bridge", "start", "--daemon", "--capability", "agent-tui"],
    );
    assert!(output.status.success(), "start: {}", output_text(&output));

    let state = wait_for_bridge_state(&data_home);
    assert!(PathBuf::from(&state.socket_path).starts_with("/tmp"));
    assert!(
        state.socket_path.len() < 103,
        "socket path should fit unix-domain limits: {}",
        state.socket_path
    );

    let stop_output = run_bridge_with_data_home(&data_home, &["bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "stop: {}",
        output_text(&stop_output)
    );
    assert!(
        !PathBuf::from(&state.socket_path).exists(),
        "socket should be removed after stop"
    );
}

#[test]
fn bridge_reconfigure_requires_force_to_disable_agent_tui_with_active_sessions() {
    let tmp = tempdir().expect("tempdir");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&project).expect("create project");

    let mut bridge = Command::new(harness_binary())
        .args(["bridge", "start", "--capability", "agent-tui"])
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_SANDBOXED")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn bridge");

    let _state = wait_for_bridge_state(tmp.path());
    temp_env::with_vars(
        [
            (
                "HARNESS_DAEMON_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 daemon root")),
            ),
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 daemon root")),
            ),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_SANDBOXED", None),
        ],
        || {
            let client = BridgeClient::from_state_file().expect("bridge client");
            let snapshot = client
                .agent_tui_start(&AgentTuiStartSpec {
                    session_id: "session-1".to_string(),
                    agent_id: "agent-1".to_string(),
                    tui_id: "agent-tui-1".to_string(),
                    profile: AgentTuiLaunchProfile::from_argv(
                        "codex",
                        vec!["sh".to_string(), "-c".to_string(), "cat".to_string()],
                    )
                    .expect("launch profile"),
                    project_dir: project.clone(),
                    transcript_path: tmp.path().join("transcript.log"),
                    size: AgentTuiSize { rows: 24, cols: 80 },
                    prompt: None,
                })
                .expect("start agent tui");
            assert_eq!(snapshot.tui_id, "agent-tui-1");
        },
    );

    let output = run_bridge(&tmp, &["bridge", "reconfigure", "--disable", "agent-tui"]);
    assert!(
        !output.status.success(),
        "disable should fail without force: {}",
        output_text(&output)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("KSRCLI092") || stderr.contains("--force"));

    let forced_output = run_bridge(
        &tmp,
        &[
            "bridge",
            "reconfigure",
            "--disable",
            "agent-tui",
            "--force",
            "--json",
        ],
    );
    assert!(
        forced_output.status.success(),
        "forced disable: {}",
        output_text(&forced_output)
    );
    let report: BridgeStatusReport =
        serde_json::from_slice(&forced_output.stdout).expect("parse status");
    assert!(!report.capabilities.contains_key("agent-tui"));

    let stop_output = run_bridge(&tmp, &["bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "cleanup stop: {}",
        output_text(&stop_output)
    );
    wait_for_bridge_exit(&mut bridge);
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
    run_bridge_with_data_home(tmp.path(), args)
}

fn run_bridge_with_data_home(data_home: &Path, args: &[&str]) -> Output {
    Command::new(harness_binary())
        .args(args)
        .env("HARNESS_DAEMON_DATA_HOME", data_home)
        .env("XDG_DATA_HOME", data_home)
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
