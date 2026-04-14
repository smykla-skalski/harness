use super::*;

#[test]
fn sandboxed_codex_run_returns_501_when_bridge_excludes_codex() {
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
        "sandboxed-codex-excluded",
        "bridge exclusion coverage",
        "verify sandboxed host bridge exclusions",
    );
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    let (http_status, body) = post_json(
        &endpoint,
        &token,
        &format!("/v1/sessions/{}/codex-runs", session.session_id),
        json!({
            "prompt": "verify excluded codex capability",
            "mode": "report",
        }),
    );
    assert_eq!(http_status, 501, "unexpected body: {body}");
    assert_eq!(body["error"], "sandbox-disabled");
    assert_eq!(body["feature"], "codex.host-bridge");

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
fn sandboxed_codex_run_succeeds_immediately_after_bridge_start_with_codex() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo(&project);

    let mock_codex = create_mock_codex(tmp.path());
    let codex_port = unused_local_port();
    let codex_port_text = codex_port.to_string();
    let mut daemon = spawn_daemon_serve_with_args(&home, &xdg, &["--sandboxed"]);
    let _initial_status = wait_for_daemon_ready(&home, &xdg);
    let mut bridge = spawn_bridge(
        &home,
        &xdg,
        &[
            "--capability",
            "codex",
            "--codex-port",
            &codex_port_text,
            "--codex-path",
            mock_codex.to_str().expect("utf8 codex path"),
        ],
    );
    let _bridge_status = wait_for_bridge_capabilities(&home, &xdg, &["codex"]);
    let _daemon_ready = wait_for_daemon_ready(&home, &xdg);

    let project_arg = project.to_str().expect("utf8 project");
    let session = start_session_via_http(
        &home,
        &xdg,
        project_arg,
        "sandboxed-codex-run-ready-bridge",
        "bridge readiness coverage",
        "verify codex runs queue immediately after bridge startup",
    );
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    let (http_status, body) = post_json(
        &endpoint,
        &token,
        &format!("/v1/sessions/{}/codex-runs", session.session_id),
        json!({
            "prompt": "verify queued codex run after readiness-gated bridge start",
            "mode": "report",
        }),
    );
    assert_eq!(http_status, 200, "unexpected body: {body}");
    let snapshot: CodexRunSnapshot =
        serde_json::from_value(body).expect("parse codex run snapshot");
    assert_eq!(snapshot.session_id, session.session_id);
    assert_eq!(snapshot.status, CodexRunStatus::Queued);
    assert_eq!(
        snapshot.mode,
        harness::daemon::protocol::CodexRunMode::Report
    );
    assert!(
        snapshot.run_id.starts_with("codex-"),
        "unexpected run id: {}",
        snapshot.run_id
    );

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
fn sandboxed_agent_tui_start_returns_501_when_bridge_excludes_agent_tui() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo(&project);

    let mock_codex = create_mock_codex(tmp.path());
    let codex_port = unused_local_port();
    let codex_port_text = codex_port.to_string();
    let mut daemon = spawn_daemon_serve_with_args(&home, &xdg, &["--sandboxed"]);
    let _initial_status = wait_for_daemon_ready(&home, &xdg);
    let mut bridge = spawn_bridge(
        &home,
        &xdg,
        &[
            "--capability",
            "codex",
            "--codex-port",
            &codex_port_text,
            "--codex-path",
            mock_codex.to_str().expect("utf8 codex path"),
        ],
    );
    let _bridge_status = wait_for_bridge_capabilities(&home, &xdg, &["codex"]);
    let _daemon_ready = wait_for_daemon_ready(&home, &xdg);

    let project_arg = project.to_str().expect("utf8 project");
    let session = start_session_via_http(
        &home,
        &xdg,
        project_arg,
        "sandboxed-agent-tui-excluded",
        "bridge exclusion coverage",
        "verify sandboxed host bridge exclusions",
    );
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    let (http_status, body) = post_json(
        &endpoint,
        &token,
        &format!("/v1/sessions/{}/agent-tuis", session.session_id),
        json!({
            "runtime": "codex",
            "name": "Excluded TUI",
            "prompt": "verify excluded agent-tui capability",
            "argv": ["sh", "-c", "cat"],
            "rows": 24,
            "cols": 80,
        }),
    );
    assert_eq!(http_status, 501, "unexpected body: {body}");
    assert_eq!(body["error"], "sandbox-disabled");
    assert_eq!(body["feature"], "agent-tui.host-bridge");

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
fn sandboxed_agent_tui_start_succeeds_after_http_bridge_reconfigure_enable() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo(&project);

    let mock_codex = create_mock_codex(tmp.path());
    let codex_port = unused_local_port();
    let codex_port_text = codex_port.to_string();
    let mut daemon = spawn_daemon_serve_with_args(&home, &xdg, &["--sandboxed"]);
    let _initial_status = wait_for_daemon_ready(&home, &xdg);
    let mut bridge = spawn_bridge(
        &home,
        &xdg,
        &[
            "--capability",
            "codex",
            "--codex-port",
            &codex_port_text,
            "--codex-path",
            mock_codex.to_str().expect("utf8 codex path"),
        ],
    );
    let _bridge_status = wait_for_bridge_capabilities(&home, &xdg, &["codex"]);
    let _daemon_ready = wait_for_daemon_ready(&home, &xdg);

    let project_arg = project.to_str().expect("utf8 project");
    let session = start_session_via_http(
        &home,
        &xdg,
        project_arg,
        "sandboxed-agent-tui-reconfigure",
        "bridge exclusion coverage",
        "verify sandboxed host bridge exclusions",
    );
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    let (reconfigure_status, reconfigure_body) = post_json(
        &endpoint,
        &token,
        "/v1/bridge/reconfigure",
        json!({
            "enable": ["agent-tui"],
        }),
    );
    assert_eq!(
        reconfigure_status, 200,
        "unexpected body: {reconfigure_body}"
    );
    assert!(reconfigure_body["capabilities"]["codex"].is_object());
    assert!(reconfigure_body["capabilities"]["agent-tui"].is_object());
    let _bridge_status = wait_for_bridge_capabilities(&home, &xdg, &["codex", "agent-tui"]);
    let _daemon_ready = wait_for_daemon_ready(&home, &xdg);

    let (http_status, body) = post_json(
        &endpoint,
        &token,
        &format!("/v1/sessions/{}/agent-tuis", session.session_id),
        json!({
            "runtime": "codex",
            "name": "Reconfigured TUI",
            "prompt": "verify enabled agent-tui capability",
            "argv": ["sh", "-c", "cat"],
            "rows": 24,
            "cols": 80,
        }),
    );
    assert_eq!(http_status, 200, "unexpected body: {body}");
    let snapshot: AgentTuiSnapshot =
        serde_json::from_value(body).expect("parse agent tui snapshot");
    assert_eq!(snapshot.status, AgentTuiStatus::Running);

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
fn sandboxed_bridge_reconfigure_disable_agent_tui_requires_force_over_http() {
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
        "sandboxed-agent-tui-disable-force",
        "bridge exclusion coverage",
        "verify sandboxed host bridge exclusions",
    );
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    let (start_status, start_body) = post_json(
        &endpoint,
        &token,
        &format!("/v1/sessions/{}/agent-tuis", session.session_id),
        json!({
            "runtime": "codex",
            "name": "Disable force TUI",
            "prompt": "verify reconfigure conflict mapping",
            "argv": ["sh", "-c", "cat"],
            "rows": 24,
            "cols": 80,
        }),
    );
    assert_eq!(start_status, 200, "unexpected body: {start_body}");

    let (reconfigure_status, reconfigure_body) = post_json(
        &endpoint,
        &token,
        "/v1/bridge/reconfigure",
        json!({
            "disable": ["agent-tui"],
        }),
    );
    assert_eq!(
        reconfigure_status, 409,
        "unexpected body: {reconfigure_body}"
    );
    assert_eq!(reconfigure_body["error"]["code"], "KSRCLI092");
    assert!(
        reconfigure_body["error"]["message"]
            .as_str()
            .is_some_and(|message| message.contains("--force")),
        "unexpected body: {reconfigure_body}"
    );

    let (forced_status, forced_body) = post_json(
        &endpoint,
        &token,
        "/v1/bridge/reconfigure",
        json!({
            "disable": ["agent-tui"],
            "force": true,
        }),
    );
    assert_eq!(forced_status, 200, "unexpected body: {forced_body}");
    assert!(forced_body["capabilities"]["agent-tui"].is_null());
    let _bridge_status = wait_for_bridge_capabilities(&home, &xdg, &[]);
    let _daemon_ready = wait_for_daemon_ready(&home, &xdg);

    let (restart_status, restart_body) = post_json(
        &endpoint,
        &token,
        &format!("/v1/sessions/{}/agent-tuis", session.session_id),
        json!({
            "runtime": "codex",
            "name": "Excluded again",
            "prompt": "verify excluded agent-tui capability",
            "argv": ["sh", "-c", "cat"],
            "rows": 24,
            "cols": 80,
        }),
    );
    assert_eq!(restart_status, 501, "unexpected body: {restart_body}");
    assert_eq!(restart_body["error"], "sandbox-disabled");
    assert_eq!(restart_body["feature"], "agent-tui.host-bridge");

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
