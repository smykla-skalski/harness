use super::*;

#[test]
fn sandboxed_agent_tui_start_succeeds_with_host_bridge() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo(&project);

    let mut daemon = spawn_daemon_serve_with_args(&home, &xdg, &["--sandboxed"]);
    let _initial_status = wait_for_daemon_ready(&home, &xdg);
    let mut bridge = spawn_bridge(&home, &xdg, &["--capability", "agent-tui"]);
    let _bridge_status = wait_for_bridge_capabilities(&home, &xdg, &["agent-tui"]);
    let _daemon_ready = wait_for_daemon_ready(&home, &xdg);

    let project_arg = project.to_str().expect("utf8 project");
    let session = start_session_via_http(
        &home,
        &xdg,
        project_arg,
        "sandboxed-agent-tui-session",
        "sandboxed agent tui",
        "verify sandboxed daemon can start bridged agent tui",
    );

    let start_output = run_harness_with_timeout(
        &home,
        &xdg,
        &[
            "session",
            "tui",
            "start",
            session.session_id.as_str(),
            "--runtime",
            "codex",
            "--role",
            "worker",
            "--name",
            "Shell TUI",
            "--arg=sh",
            "--arg=-c",
            "--arg=cat",
        ],
        COMMAND_WAIT_TIMEOUT,
    );
    assert!(
        start_output.status.success(),
        "tui start failed: {}",
        output_text(&start_output)
    );
    let started: AgentTuiSnapshot =
        serde_json::from_slice(&start_output.stdout).expect("parse tui start");
    assert_eq!(started.status, AgentTuiStatus::Running);
    assert_eq!(started.session_id, session.session_id);

    let text_output = run_harness(
        &home,
        &xdg,
        &[
            "session",
            "tui",
            "input",
            started.tui_id.as_str(),
            "--text",
            "bridge ok",
        ],
    );
    assert!(
        text_output.status.success(),
        "tui text failed: {}",
        output_text(&text_output)
    );

    let enter_output = run_harness(
        &home,
        &xdg,
        &[
            "session",
            "tui",
            "input",
            started.tui_id.as_str(),
            "--key",
            "enter",
        ],
    );
    assert!(
        enter_output.status.success(),
        "tui enter failed: {}",
        output_text(&enter_output)
    );
    let echoed: AgentTuiSnapshot =
        serde_json::from_slice(&enter_output.stdout).expect("parse tui input");
    assert!(echoed.screen.text.contains("bridge ok"));

    let stop_output = run_harness(
        &home,
        &xdg,
        &["session", "tui", "stop", started.tui_id.as_str()],
    );
    assert!(
        stop_output.status.success(),
        "tui stop failed: {}",
        output_text(&stop_output)
    );
    let stopped: AgentTuiSnapshot =
        serde_json::from_slice(&stop_output.stdout).expect("parse tui stop");
    assert_eq!(stopped.status, AgentTuiStatus::Stopped);

    let bridge_stop_output = run_harness(&home, &xdg, &["bridge", "stop"]);
    assert!(
        bridge_stop_output.status.success(),
        "bridge stop failed: {}",
        output_text(&bridge_stop_output)
    );
    wait_for_child_exit(&mut bridge);

    daemon.kill().expect("kill daemon");
    wait_for_child_exit(&mut daemon);
}

#[test]
fn cli_tui_commands_follow_running_app_group_daemon_root() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo(&project);

    let mut daemon = ManagedChild::spawn(
        Command::new(harness_binary())
            .args([
                "daemon",
                "serve",
                "--host",
                "127.0.0.1",
                "--port",
                "0",
                "--sandboxed",
            ])
            .env("HARNESS_HOST_HOME", &home)
            .env("HOME", &home)
            .env("XDG_DATA_HOME", &xdg)
            .env("HARNESS_APP_GROUP_ID", HARNESS_MONITOR_APP_GROUP_ID)
            .env("HARNESS_SANDBOXED", "1")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null()),
    )
    .expect("spawn app-group daemon");

    let _manifest = wait_for_app_group_daemon_ready(&home);
    let status_output = run_harness(&home, &xdg, &["daemon", "status"]);
    assert!(
        status_output.status.success(),
        "daemon status failed: {}",
        output_text(&status_output)
    );
    let status: DaemonStatusReport =
        serde_json::from_slice(&status_output.stdout).expect("parse daemon status");
    assert!(
        status.manifest.is_some(),
        "daemon status should discover the running app-group daemon"
    );

    let mut bridge = spawn_bridge(&home, &xdg, &["--capability", "agent-tui"]);
    let _bridge_status = wait_for_bridge_capabilities(&home, &xdg, &["agent-tui"]);

    let project_arg = project.to_str().expect("utf8 project");
    let (endpoint, token) = current_app_group_daemon_endpoint_and_token(&home);
    let (session_status, session_body) = post_json(
        &endpoint,
        &token,
        "/v1/sessions",
        json!({
            "title": "app group tui",
            "context": "prove cli tui commands follow the running app-group daemon",
            "runtime": "codex",
            "session_id": "app-group-cli-tui",
            "project_dir": project_arg,
        }),
    );
    assert_eq!(
        session_status, 200,
        "unexpected session status: {session_body}"
    );

    let start_output = run_harness_with_timeout(
        &home,
        &xdg,
        &[
            "session",
            "tui",
            "start",
            "app-group-cli-tui",
            "--runtime",
            "codex",
            "--role",
            "worker",
            "--name",
            "Shell TUI",
            "--arg=sh",
            "--arg=-c",
            "--arg=cat",
        ],
        COMMAND_WAIT_TIMEOUT,
    );
    assert!(
        start_output.status.success(),
        "cli tui start failed: {}",
        output_text(&start_output)
    );
    let started: AgentTuiSnapshot =
        serde_json::from_slice(&start_output.stdout).expect("parse tui start");
    assert_eq!(started.status, AgentTuiStatus::Running);

    let text_output = run_harness(
        &home,
        &xdg,
        &[
            "session",
            "tui",
            "input",
            started.tui_id.as_str(),
            "--text",
            "bridge ok",
        ],
    );
    assert!(
        text_output.status.success(),
        "cli tui text failed: {}",
        output_text(&text_output)
    );

    let enter_output = run_harness(
        &home,
        &xdg,
        &[
            "session",
            "tui",
            "input",
            started.tui_id.as_str(),
            "--key",
            "enter",
        ],
    );
    assert!(
        enter_output.status.success(),
        "cli tui enter failed: {}",
        output_text(&enter_output)
    );
    let echoed: AgentTuiSnapshot =
        serde_json::from_slice(&enter_output.stdout).expect("parse tui input");
    assert!(echoed.screen.text.contains("bridge ok"));

    let stop_output = run_harness(
        &home,
        &xdg,
        &["session", "tui", "stop", started.tui_id.as_str()],
    );
    assert!(
        stop_output.status.success(),
        "cli tui stop failed: {}",
        output_text(&stop_output)
    );
    let stopped: AgentTuiSnapshot =
        serde_json::from_slice(&stop_output.stdout).expect("parse tui stop");
    assert_eq!(stopped.status, AgentTuiStatus::Stopped);

    let bridge_stop_output = run_harness(&home, &xdg, &["bridge", "stop"]);
    assert!(
        bridge_stop_output.status.success(),
        "bridge stop failed: {}",
        output_text(&bridge_stop_output)
    );
    wait_for_child_exit(&mut bridge);

    daemon.kill().expect("kill daemon");
    wait_for_child_exit(&mut daemon);
}
