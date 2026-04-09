use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use harness::daemon::service::DaemonStatusReport;
use harness::session::types::SessionState;
use tempfile::tempdir;
use tokio::runtime::Runtime;

const DAEMON_WAIT_TIMEOUT: Duration = Duration::from_secs(15);
const DAEMON_WAIT_INTERVAL: Duration = Duration::from_millis(250);
const DAEMON_HTTP_TIMEOUT: Duration = Duration::from_secs(1);

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
    let _status = wait_for_daemon_ready(&home, &xdg);

    let project_arg = project.to_str().expect("utf8 project");
    let start_output = run_harness(
        &home,
        &xdg,
        &[
            "session",
            "start",
            "--title",
            "daemon-only integration",
            "--context",
            "verify daemon-backed session lookup after list",
            "--runtime",
            "codex",
            "--session-id",
            "daemon-only-session",
            "--project-dir",
            project_arg,
        ],
    );
    assert!(
        start_output.status.success(),
        "session start failed: {}",
        output_text(&start_output)
    );
    let started: SessionState =
        serde_json::from_slice(&start_output.stdout).expect("parse session start");

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

fn spawn_daemon_serve(home: &Path, xdg: &Path) -> Child {
    Command::new(harness_binary())
        .args(["daemon", "serve", "--host", "127.0.0.1", "--port", "0"])
        .env("HOME", home)
        .env("XDG_DATA_HOME", xdg)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn daemon serve")
}

fn run_harness(home: &Path, xdg: &Path, args: &[&str]) -> Output {
    Command::new(harness_binary())
        .args(args)
        .env("HOME", home)
        .env("XDG_DATA_HOME", xdg)
        .output()
        .expect("run harness")
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
                {
                    return status;
                }
                "daemon status did not report a healthy manifest yet".to_string()
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

fn harness_binary() -> PathBuf {
    assert_cmd::cargo::cargo_bin("harness")
}

fn output_text(output: &Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    format!("stdout={stdout:?} stderr={stderr:?}")
}
