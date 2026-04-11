use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use harness::daemon::agent_tui::{AgentTuiSnapshot, AgentTuiStatus};
use harness::daemon::bridge::BridgeStatusReport;
use harness::daemon::protocol::SessionMutationResponse;
use harness::daemon::service::DaemonStatusReport;
use harness::session::types::SessionState;
use serde_json::{Value, json};
use tempfile::tempdir;
use tokio::runtime::Runtime;

const DAEMON_WAIT_TIMEOUT: Duration = Duration::from_secs(15);
const DAEMON_WAIT_INTERVAL: Duration = Duration::from_millis(250);
const DAEMON_HTTP_TIMEOUT: Duration = Duration::from_secs(1);
const COMMAND_WAIT_TIMEOUT: Duration = Duration::from_secs(10);

#[test]
fn daemon_stop_stops_running_manual_daemon() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    let _status = wait_for_daemon_ready(&home, &xdg);

    let output = run_harness(&home, &xdg, &["daemon", "stop"]);
    assert!(
        output.status.success(),
        "stop failed: {}",
        output_text(&output)
    );
    assert_eq!(String::from_utf8_lossy(&output.stdout), "stopped\n");

    wait_for_daemon_stopped(&home, &xdg);
    wait_for_child_exit(&mut daemon);
}

#[test]
fn daemon_stop_succeeds_when_offline() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let output = run_harness(&home, &xdg, &["daemon", "stop"]);
    assert!(
        output.status.success(),
        "stop failed: {}",
        output_text(&output)
    );
    assert_eq!(String::from_utf8_lossy(&output.stdout), "stopped\n");
}

#[test]
fn daemon_restart_starts_manual_daemon_when_offline() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let output = run_harness(&home, &xdg, &["daemon", "restart"]);
    assert!(
        output.status.success(),
        "restart failed: {}",
        output_text(&output)
    );
    assert_eq!(String::from_utf8_lossy(&output.stdout), "restarted\n");

    let status = wait_for_daemon_ready(&home, &xdg);
    assert!(
        status.manifest.is_some(),
        "restart should create a manifest"
    );

    let stop_output = run_harness(&home, &xdg, &["daemon", "stop"]);
    assert!(
        stop_output.status.success(),
        "cleanup stop failed: {}",
        output_text(&stop_output)
    );
}

#[test]
fn daemon_restart_replaces_running_manual_daemon() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    let initial_status = wait_for_daemon_ready(&home, &xdg);
    let initial_pid = initial_status
        .manifest
        .as_ref()
        .expect("initial manifest")
        .pid;

    let output = run_harness(&home, &xdg, &["daemon", "restart"]);
    assert!(
        output.status.success(),
        "restart failed: {}",
        output_text(&output)
    );
    assert_eq!(String::from_utf8_lossy(&output.stdout), "restarted\n");

    wait_for_child_exit(&mut daemon);
    let restarted_status = wait_for_daemon_ready(&home, &xdg);
    let restarted_pid = restarted_status
        .manifest
        .as_ref()
        .expect("restarted manifest")
        .pid;
    assert_ne!(
        restarted_pid, initial_pid,
        "restart should replace the process"
    );

    let stop_output = run_harness(&home, &xdg, &["daemon", "stop"]);
    assert!(
        stop_output.status.success(),
        "cleanup stop failed: {}",
        output_text(&stop_output)
    );
}

#[test]
fn daemon_only_session_status_and_end_work_after_list() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo(&project);

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    let project_arg = project.to_str().expect("utf8 project");
    let started = start_session_via_http(
        &home,
        &xdg,
        project_arg,
        "daemon-only-session",
        "daemon-only integration",
        "verify daemon-backed session lookup after list",
    );

    let list_output = run_harness(&home, &xdg, &["session", "list", "--json"]);
    assert!(
        list_output.status.success(),
        "session list failed: {}",
        output_text(&list_output)
    );
    let listed: Vec<SessionState> =
        serde_json::from_slice(&list_output.stdout).expect("parse session list");
    assert!(
        listed
            .iter()
            .any(|session| session.session_id == started.session_id)
    );

    let status_output = run_harness(
        &home,
        &xdg,
        &[
            "session",
            "status",
            "daemon-only-session",
            "--json",
            "--project-dir",
            project_arg,
        ],
    );
    assert!(
        status_output.status.success(),
        "session status failed: {}",
        output_text(&status_output)
    );
    let status: SessionState =
        serde_json::from_slice(&status_output.stdout).expect("parse session status");
    assert_eq!(status.session_id, started.session_id);

    let end_output = run_harness(
        &home,
        &xdg,
        &[
            "session",
            "end",
            "daemon-only-session",
            "--actor",
            "codex-leader",
            "--project-dir",
            project_arg,
        ],
    );
    assert!(
        end_output.status.success(),
        "session end failed: {}",
        output_text(&end_output)
    );

    daemon.kill().expect("kill daemon");
    wait_for_child_exit(&mut daemon);
}

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
fn sandboxed_agent_tui_start_returns_501_when_bridge_excludes_agent_tui() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo(&project);

    let mock_codex = create_mock_codex(tmp.path());
    let mut daemon = spawn_daemon_serve_with_args(&home, &xdg, &["--sandboxed"]);
    let _initial_status = wait_for_daemon_ready(&home, &xdg);
    let mut bridge = spawn_bridge(
        &home,
        &xdg,
        &[
            "--capability",
            "codex",
            "--codex-port",
            "14511",
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
    let mut daemon = spawn_daemon_serve_with_args(&home, &xdg, &["--sandboxed"]);
    let _initial_status = wait_for_daemon_ready(&home, &xdg);
    let mut bridge = spawn_bridge(
        &home,
        &xdg,
        &[
            "--capability",
            "codex",
            "--codex-port",
            "14512",
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

fn spawn_daemon_serve(home: &Path, xdg: &Path) -> Child {
    spawn_daemon_serve_with_args(home, xdg, &[])
}

fn spawn_daemon_serve_with_args(home: &Path, xdg: &Path, extra_args: &[&str]) -> Child {
    let mut args = vec!["daemon", "serve", "--host", "127.0.0.1", "--port", "0"];
    args.extend(extra_args);
    Command::new(harness_binary())
        .args(&args)
        .env("HARNESS_HOST_HOME", home)
        .env("HOME", home)
        .env("HARNESS_HOST_HOME", home)
        .env("XDG_DATA_HOME", xdg)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn daemon serve")
}

fn spawn_bridge(home: &Path, xdg: &Path, extra_args: &[&str]) -> Child {
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let mut args = vec!["bridge", "start"];
        args.extend(extra_args);
        let mut child = Command::new(harness_binary())
            .args(&args)
            .env("HARNESS_HOST_HOME", home)
            .env("HOME", home)
            .env("HARNESS_HOST_HOME", home)
            .env("XDG_DATA_HOME", xdg)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn agent tui bridge");

        let startup_deadline = Instant::now() + Duration::from_secs(1);
        loop {
            match child.try_wait().expect("poll bridge start") {
                Some(_) => {
                    let output = child.wait_with_output().expect("collect bridge output");
                    if Instant::now() >= deadline {
                        panic!("bridge start failed: {}", output_text(&output));
                    }
                    thread::sleep(DAEMON_WAIT_INTERVAL);
                    break;
                }
                None if Instant::now() >= startup_deadline => return child,
                None => thread::sleep(DAEMON_WAIT_INTERVAL),
            }
        }
    }
}

fn run_harness(home: &Path, xdg: &Path, args: &[&str]) -> Output {
    Command::new(harness_binary())
        .args(args)
        .env("HARNESS_HOST_HOME", home)
        .env("HOME", home)
        .env("HARNESS_HOST_HOME", home)
        .env("XDG_DATA_HOME", xdg)
        .output()
        .expect("run harness")
}

fn run_harness_with_timeout(home: &Path, xdg: &Path, args: &[&str], timeout: Duration) -> Output {
    let mut child = Command::new(harness_binary())
        .args(args)
        .env("HARNESS_HOST_HOME", home)
        .env("HOME", home)
        .env("HARNESS_HOST_HOME", home)
        .env("XDG_DATA_HOME", xdg)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn harness");

    let deadline = Instant::now() + timeout;
    loop {
        if child.try_wait().expect("poll harness").is_some() {
            return child.wait_with_output().expect("collect harness output");
        }
        if Instant::now() >= deadline {
            child.kill().expect("kill timed out harness process");
            let output = child.wait_with_output().expect("collect timed out output");
            panic!(
                "command did not exit before timeout: args={args:?} output={}",
                output_text(&output)
            );
        }
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

fn init_git_repo(path: &Path) {
    std::fs::create_dir_all(path).expect("create project");
    let status = Command::new("git")
        .arg("init")
        .arg("-q")
        .arg(path)
        .status()
        .expect("git init");
    assert!(status.success(), "git init failed");
}

fn wait_for_daemon_ready(home: &Path, xdg: &Path) -> DaemonStatusReport {
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let retry_reason = match try_daemon_status(home, xdg) {
            Ok(status) => {
                if let Some(manifest) = status.manifest.as_ref()
                    && endpoint_is_healthy(&manifest.endpoint)
                    && session_api_is_ready(home, xdg)
                {
                    return status;
                }
                "daemon status did not report a healthy manifest with a ready session API yet"
                    .to_string()
            }
            Err(error) => error,
        };
        assert!(
            Instant::now() < deadline,
            "daemon did not become healthy before timeout: {}",
            retry_reason
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

fn wait_for_daemon_stopped(home: &Path, xdg: &Path) {
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let retry_reason = match try_daemon_status(home, xdg) {
            Ok(status) => {
                if status.manifest.is_none() {
                    return;
                }
                "daemon status still reports a manifest".to_string()
            }
            Err(error) => error,
        };
        assert!(
            Instant::now() < deadline,
            "daemon did not stop before timeout: {}",
            retry_reason
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

fn wait_for_child_exit(child: &mut Child) {
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        if child.try_wait().expect("poll child").is_some() {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "daemon child did not exit before timeout"
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

fn wait_for_bridge_capabilities(
    home: &Path,
    xdg: &Path,
    required_capabilities: &[&str],
) -> BridgeStatusReport {
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let output = run_harness(home, xdg, &["bridge", "status"]);
        if output.status.success() {
            let report: BridgeStatusReport =
                serde_json::from_slice(&output.stdout).expect("parse bridge status");
            if report.running
                && required_capabilities
                    .iter()
                    .all(|capability| report.capabilities.contains_key(*capability))
            {
                return report;
            }
        }
        assert!(
            Instant::now() < deadline,
            "bridge did not become ready before timeout: {}",
            output_text(&output)
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

fn try_daemon_status(home: &Path, xdg: &Path) -> Result<DaemonStatusReport, String> {
    let output = run_harness(home, xdg, &["daemon", "status"]);
    if !output.status.success() {
        return Err(output_text(&output));
    }
    serde_json::from_slice(&output.stdout).map_err(|error| {
        format!(
            "parse daemon status: {error}; raw={}",
            String::from_utf8_lossy(&output.stdout)
        )
    })
}

fn endpoint_is_healthy(endpoint: &str) -> bool {
    let url = format!("{}/v1/health", endpoint.trim_end_matches('/'));
    Runtime::new().expect("runtime").block_on(async {
        reqwest::Client::new()
            .get(&url)
            .timeout(DAEMON_HTTP_TIMEOUT)
            .send()
            .await
            .is_ok_and(|response| response.status().is_success())
    })
}

fn session_api_is_ready(home: &Path, xdg: &Path) -> bool {
    let output = run_harness(home, xdg, &["session", "list", "--json"]);
    output.status.success()
}

fn post_json(endpoint: &str, token: &str, path: &str, body: Value) -> (u16, Value) {
    let url = format!(
        "{}/{}",
        endpoint.trim_end_matches('/'),
        path.trim_start_matches('/')
    );
    let token = token.to_string();
    let runtime = Runtime::new().expect("runtime");
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let request_body = body.clone();
        let client = reqwest::Client::new();
        let response = runtime.block_on(async {
            client
                .post(&url)
                .bearer_auth(token.clone())
                .json(&request_body)
                .timeout(DAEMON_HTTP_TIMEOUT)
                .send()
                .await
        });
        match response {
            Ok(response) => {
                let status = response.status().as_u16();
                let json =
                    runtime.block_on(async { response.json::<Value>().await.expect("json body") });
                return (status, json);
            }
            Err(error) if error.is_connect() || error.is_timeout() => {
                if Instant::now() >= deadline {
                    panic!("daemon post: {error:?}");
                }
                thread::sleep(DAEMON_WAIT_INTERVAL);
            }
            Err(error) => panic!("daemon post: {error:?}"),
        }
    }
}

fn read_daemon_token(token_path: &str) -> String {
    std::fs::read_to_string(token_path)
        .expect("read daemon token")
        .trim()
        .to_string()
}

fn start_session_via_http(
    home: &Path,
    xdg: &Path,
    project_arg: &str,
    session_id: &str,
    title: &str,
    context: &str,
) -> SessionState {
    let runtime = Runtime::new().expect("runtime");
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    let request_body = json!({
        "title": title,
        "context": context,
        "runtime": "codex",
        "session_id": session_id,
        "project_dir": project_arg,
    });

    loop {
        let (endpoint, token) = current_daemon_endpoint_and_token(home, xdg);
        let url = format!("{}/v1/sessions", endpoint.trim_end_matches('/'));
        let client = reqwest::Client::new();
        let response = runtime.block_on(async {
            client
                .post(&url)
                .bearer_auth(&token)
                .json(&request_body)
                .timeout(DAEMON_HTTP_TIMEOUT)
                .send()
                .await
        });

        match response {
            Ok(response) => {
                let status = response.status().as_u16();
                let body =
                    runtime.block_on(async { response.json::<Value>().await.expect("json body") });
                if status == 200 {
                    return serde_json::from_value::<SessionMutationResponse>(body)
                        .expect("parse session start")
                        .state;
                }
                if status == 409
                    && let Some(state) = read_session_status(home, xdg, project_arg, session_id)
                {
                    return state;
                }
                panic!("unexpected body: {body}");
            }
            Err(error) if session_start_error_is_retryable(&error) => {
                if let Some(state) = read_session_status(home, xdg, project_arg, session_id) {
                    return state;
                }
                if Instant::now() >= deadline {
                    panic!("daemon post: {error:?}");
                }
                thread::sleep(DAEMON_WAIT_INTERVAL);
            }
            Err(error) => panic!("daemon post: {error:?}"),
        }
    }
}

fn current_daemon_endpoint_and_token(home: &Path, xdg: &Path) -> (String, String) {
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        match try_daemon_status(home, xdg) {
            Ok(status) => {
                if let Some(manifest) = status.manifest.as_ref() {
                    return (
                        manifest.endpoint.clone(),
                        read_daemon_token(&manifest.token_path),
                    );
                }
            }
            Err(_) => {}
        }

        assert!(
            Instant::now() < deadline,
            "daemon manifest did not become available before timeout"
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

fn read_session_status(
    home: &Path,
    xdg: &Path,
    project_arg: &str,
    session_id: &str,
) -> Option<SessionState> {
    let output = run_harness(
        home,
        xdg,
        &[
            "session",
            "status",
            session_id,
            "--json",
            "--project-dir",
            project_arg,
        ],
    );
    output
        .status
        .success()
        .then(|| serde_json::from_slice(&output.stdout).expect("parse session status"))
}

fn session_start_error_is_retryable(error: &reqwest::Error) -> bool {
    if error.is_connect() || error.is_timeout() {
        return true;
    }

    error.is_request()
}

fn create_mock_codex(base: &Path) -> PathBuf {
    let script = base.join("mock-codex");
    std::fs::write(
        &script,
        concat!(
            "#!/bin/sh\n",
            "if [ \"$1\" = \"--version\" ]; then\n",
            "  echo 'mock-codex 0.0.1'\n",
            "  exit 0\n",
            "fi\n",
            "sleep 300\n",
        ),
    )
    .expect("write mock codex");
    std::fs::set_permissions(
        &script,
        std::fs::Permissions::from(std::os::unix::fs::PermissionsExt::from_mode(0o755)),
    )
    .expect("chmod mock codex");
    script
}

fn harness_binary() -> PathBuf {
    assert_cmd::cargo::cargo_bin("harness")
}

fn output_text(output: &Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    format!("stdout={stdout:?} stderr={stderr:?}")
}
