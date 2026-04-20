// Shared helpers for workspace integration tests.

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use harness::daemon::protocol::SessionMutationResponse;
use harness::session::types::SessionState;
use serde_json::{Value, json};
use tokio::runtime::Runtime;

pub const DAEMON_WAIT_TIMEOUT: Duration = Duration::from_secs(15);
pub const DAEMON_WAIT_INTERVAL: Duration = Duration::from_millis(250);
pub const DAEMON_HTTP_TIMEOUT: Duration = Duration::from_secs(5);

pub fn harness_binary() -> PathBuf {
    assert_cmd::cargo::cargo_bin("harness")
}

pub fn spawn_daemon_serve(home: &Path, xdg: &Path) -> super::super::helpers::ManagedChild {
    let mut cmd = Command::new(harness_binary());
    cmd.args(["daemon", "serve", "--host", "127.0.0.1", "--port", "0"])
        .env("HARNESS_HOST_HOME", home)
        .env("HOME", home)
        .env("XDG_DATA_HOME", xdg)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    super::super::helpers::ManagedChild::spawn(&mut cmd).expect("spawn daemon serve")
}

pub fn run_harness(home: &Path, xdg: &Path, args: &[&str]) -> Output {
    Command::new(harness_binary())
        .args(args)
        .env("HARNESS_HOST_HOME", home)
        .env("HOME", home)
        .env("XDG_DATA_HOME", xdg)
        .output()
        .expect("run harness")
}

pub fn output_text(output: &Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    format!("stdout={stdout:?} stderr={stderr:?}")
}

pub fn wait_for_daemon_ready(home: &Path, xdg: &Path) {
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let output = run_harness(home, xdg, &["daemon", "status"]);
        if output.status.success() {
            if let Ok(status) = serde_json::from_slice::<serde_json::Value>(&output.stdout) {
                if status.get("manifest").is_some_and(|v| !v.is_null()) {
                    return;
                }
            }
        }
        assert!(
            Instant::now() < deadline,
            "daemon did not become healthy before timeout"
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

pub fn current_daemon_endpoint_and_token(home: &Path, xdg: &Path) -> (String, String) {
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let output = run_harness(home, xdg, &["daemon", "status"]);
        if output.status.success() {
            if let Ok(status) = serde_json::from_slice::<serde_json::Value>(&output.stdout) {
                if let (Some(endpoint), Some(token_path)) = (
                    status["manifest"]["endpoint"].as_str(),
                    status["manifest"]["token_path"].as_str(),
                ) {
                    if let Ok(token) = std::fs::read_to_string(token_path) {
                        let token = token.trim().to_string();
                        if !token.is_empty() {
                            return (endpoint.to_string(), token);
                        }
                    }
                }
            }
        }
        assert!(
            Instant::now() < deadline,
            "daemon manifest not available before timeout"
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

pub fn start_session_via_http(
    home: &Path,
    xdg: &Path,
    project_dir: &Path,
    session_id: &str,
) -> SessionState {
    let runtime = Runtime::new().expect("runtime");
    let project_arg = project_dir.to_str().expect("utf8 project path");
    let request_body = json!({
        "title": "workspace integration test",
        "context": "testing workspace layout",
        "runtime": "codex",
        "session_id": session_id,
        "project_dir": project_arg,
    });

    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
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
                if status == 409 {
                    // Already exists - try to read it.
                    let status_out = run_harness(
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
                    if status_out.status.success() {
                        return serde_json::from_slice(&status_out.stdout)
                            .expect("parse session status");
                    }
                }
                panic!("session start failed: status={status} body={body}");
            }
            Err(error) if error.is_connect() || error.is_timeout() => {
                assert!(
                    Instant::now() < deadline,
                    "daemon connection timed out: {error}"
                );
                thread::sleep(DAEMON_WAIT_INTERVAL);
            }
            Err(error) => panic!("session start request failed: {error}"),
        }
    }
}

pub fn delete_session_via_http(home: &Path, xdg: &Path, session_id: &str) -> u16 {
    let runtime = Runtime::new().expect("runtime");
    let (endpoint, token) = current_daemon_endpoint_and_token(home, xdg);
    let url = format!(
        "{}/v1/sessions/{}",
        endpoint.trim_end_matches('/'),
        session_id
    );
    let client = reqwest::Client::new();
    let response = runtime.block_on(async {
        client
            .delete(&url)
            .bearer_auth(&token)
            .timeout(DAEMON_HTTP_TIMEOUT)
            .send()
            .await
    });
    response.expect("delete request").status().as_u16()
}

pub fn git_branches_matching(repo: &Path, prefix: &str) -> Vec<String> {
    let output = Command::new("git")
        .current_dir(repo)
        .args(["branch", "--list", &format!("{prefix}*")])
        .output()
        .expect("git branch");
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(|line| {
            let trimmed = line.trim();
            let trimmed = trimmed.trim_start_matches("* ");
            let trimmed = trimmed.trim_start_matches("+ ");
            trimmed.to_string()
        })
        .filter(|line| !line.is_empty())
        .collect()
}
