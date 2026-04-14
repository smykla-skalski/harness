use super::*;

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
