use super::*;

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
