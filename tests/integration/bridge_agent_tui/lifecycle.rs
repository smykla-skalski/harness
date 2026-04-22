use super::*;

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
    let host_home = ensure_host_home(tmp.path());
    let output = Command::new(harness_binary())
        .args(["bridge", "start", "--capability", "agent-tui"])
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
fn bridge_start_publishes_agent_tui_capability_and_stops_cleanly() {
    let tmp = tempdir().expect("tempdir");
    let host_home = ensure_host_home(tmp.path());

    let mut bridge = ManagedChild::spawn(
        Command::new(harness_binary())
            .args(["bridge", "start", "--capability", "agent-tui"])
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
    let status_output = run_bridge_with_data_home(&data_home, &["bridge", "status"]);
    assert!(
        status_output.status.success(),
        "status: {}",
        output_text(&status_output)
    );
    let report: BridgeStatusReport =
        serde_json::from_slice(&status_output.stdout).expect("parse daemon bridge status");
    assert!(
        report.running,
        "daemon start should return only after the bridge is live"
    );
    assert_eq!(
        report.socket_path.as_deref(),
        Some(state.socket_path.as_str())
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
