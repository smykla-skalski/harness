// Shared helpers for workspace integration tests.

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, Instant};

use harness::daemon::protocol::SessionMutationResponse;
use harness::session::types::SessionState;
use harness::workspace::layout::SessionLayout;
use harness::workspace::{harness_data_root, layout::sessions_root};
use harness_testkit::{
    git_branches_matching as helper_git_branches_matching, git_head_sha as helper_git_head_sha,
};
use serde_json::{Value, json};
use tokio::runtime::Runtime;

pub const DAEMON_WAIT_TIMEOUT: Duration = Duration::from_secs(15);
pub const DAEMON_WAIT_INTERVAL: Duration = Duration::from_millis(250);
pub const DAEMON_HTTP_TIMEOUT: Duration = Duration::from_secs(5);

/// Shared Tokio runtime for all HTTP helpers in this module.
static RUNTIME: OnceLock<Runtime> = OnceLock::new();

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| Runtime::new().expect("tokio runtime"))
}

pub fn harness_binary() -> PathBuf {
    assert_cmd::cargo::cargo_bin("harness")
}

fn daemon_binary() -> PathBuf {
    assert_cmd::cargo::cargo_bin("harness-daemon")
}

pub fn spawn_daemon_serve(home: &Path, xdg: &Path) -> super::super::helpers::ManagedChild {
    let mut cmd = Command::new(daemon_binary());
    cmd.args(["serve", "--host", "127.0.0.1", "--port", "0"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    configure_isolated_daemon_env(&mut cmd, home, xdg);
    super::super::helpers::ManagedChild::spawn(&mut cmd).expect("spawn daemon serve")
}

pub fn run_harness(home: &Path, xdg: &Path, args: &[&str]) -> Output {
    let mut command = Command::new(harness_binary());
    command.args(args);
    configure_isolated_daemon_env(&mut command, home, xdg);
    command.output().expect("run harness")
}

fn configure_isolated_daemon_env(command: &mut Command, home: &Path, xdg: &Path) {
    command
        .env("HARNESS_HOST_HOME", home)
        .env("HOME", home)
        .env("XDG_DATA_HOME", xdg)
        .env("HARNESS_DAEMON_DATA_HOME", xdg)
        .env_remove("HARNESS_APP_GROUP_ID")
        .env_remove("HARNESS_DAEMON_OWNERSHIP")
        .env_remove("HARNESS_SANDBOXED")
        .env_remove("CLAUDE_SESSION_ID");
}

pub fn output_text(output: &Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    format!("stdout={stdout:?} stderr={stderr:?}")
}

pub fn wait_for_daemon_ready(_home: &Path, xdg: &Path) {
    let manifest_path = daemon_manifest_path(xdg);
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        if let Ok((endpoint, token)) = read_daemon_endpoint_and_token(&manifest_path)
            && daemon_endpoint_is_healthy(&endpoint, &token)
        {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "daemon did not become healthy before timeout"
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

pub fn current_daemon_endpoint_and_token(_home: &Path, xdg: &Path) -> (String, String) {
    let manifest_path = daemon_manifest_path(xdg);
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        if let Ok(endpoint_and_token) = read_daemon_endpoint_and_token(&manifest_path) {
            return endpoint_and_token;
        }
        assert!(
            Instant::now() < deadline,
            "daemon manifest not available before timeout"
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

fn daemon_manifest_path(xdg: &Path) -> PathBuf {
    xdg.join("harness")
        .join("daemon")
        .join("managed")
        .join("manifest.json")
}

fn read_daemon_endpoint_and_token(manifest_path: &Path) -> Result<(String, String), String> {
    let data = std::fs::read_to_string(manifest_path)
        .map_err(|error| format!("read {}: {error}", manifest_path.display()))?;
    let manifest: Value = serde_json::from_str(&data)
        .map_err(|error| format!("parse {}: {error}", manifest_path.display()))?;
    let endpoint = manifest["endpoint"]
        .as_str()
        .ok_or_else(|| "daemon manifest has no endpoint".to_string())?;
    let token_path = manifest["token_path"]
        .as_str()
        .ok_or_else(|| "daemon manifest has no token path".to_string())?;
    let token = std::fs::read_to_string(token_path)
        .map_err(|error| format!("read daemon token {token_path}: {error}"))?;
    let token = token.trim().to_string();
    if token.is_empty() {
        return Err("daemon token is empty".to_string());
    }
    Ok((endpoint.to_string(), token))
}

fn daemon_endpoint_is_healthy(endpoint: &str, token: &str) -> bool {
    let url = format!("{}/v1/health", endpoint.trim_end_matches('/'));
    runtime().block_on(async {
        reqwest::Client::new()
            .get(url)
            .bearer_auth(token)
            .timeout(DAEMON_HTTP_TIMEOUT)
            .send()
            .await
            .is_ok_and(|response| response.status().is_success())
    })
}

/// Attempt a session start and return `Ok(state)` on 200, or `Err((status, body))` on any
/// non-success, non-409 response. Retries on connection errors until the daemon is reachable.
/// Pass `base_ref` to route the session to a specific git ref workspace.
pub fn start_session_try(
    home: &Path,
    xdg: &Path,
    project_dir: &Path,
    session_id: &str,
    base_ref: Option<&str>,
) -> Result<SessionState, (u16, String)> {
    let project_arg = project_dir.to_str().expect("utf8 project path");
    let mut request_body = json!({
        "title": "workspace integration test",
        "context": "testing workspace layout",
        "runtime": "codex",
        "session_id": session_id,
        "project_dir": project_arg,
    });
    if let Some(bref) = base_ref {
        request_body["base_ref"] = json!(bref);
    }

    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let (endpoint, token) = current_daemon_endpoint_and_token(home, xdg);
        let url = format!("{}/v1/sessions", endpoint.trim_end_matches('/'));
        let client = reqwest::Client::new();
        let response = runtime().block_on(async {
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
                let body = runtime()
                    .block_on(async { response.json::<Value>().await.expect("json body") });
                if status == 200 {
                    return Ok(serde_json::from_value::<SessionMutationResponse>(body)
                        .expect("parse session start")
                        .state);
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
                        return Ok(serde_json::from_slice(&status_out.stdout)
                            .expect("parse session status"));
                    }
                }
                let body_text = body.to_string();
                return Err((status, body_text));
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

pub fn start_session_via_http(
    home: &Path,
    xdg: &Path,
    project_dir: &Path,
    session_id: &str,
) -> SessionState {
    start_session_try(home, xdg, project_dir, session_id, None).unwrap_or_else(|(status, body)| {
        panic!("session start failed: status={status} body={body}")
    })
}

pub fn start_session_with_base_ref(
    home: &Path,
    xdg: &Path,
    project_dir: &Path,
    session_id: &str,
    base_ref: &str,
) -> SessionState {
    start_session_try(home, xdg, project_dir, session_id, Some(base_ref)).unwrap_or_else(
        |(status, body)| panic!("session start failed: status={status} body={body}"),
    )
}

pub fn git_head_sha(repo: &Path, refname: &str) -> String {
    helper_git_head_sha(repo, refname)
}

pub fn delete_session_via_http(home: &Path, xdg: &Path, session_id: &str) -> u16 {
    let (endpoint, token) = current_daemon_endpoint_and_token(home, xdg);
    let url = format!(
        "{}/v1/sessions/{}",
        endpoint.trim_end_matches('/'),
        session_id
    );
    let client = reqwest::Client::new();
    let response = runtime().block_on(async {
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
    helper_git_branches_matching(repo, prefix)
}

pub fn layout_for_state(xdg: &std::path::Path, state: &SessionState) -> SessionLayout {
    temp_env::with_vars(
        [("XDG_DATA_HOME", Some(xdg.as_os_str().to_str().unwrap()))],
        || {
            let root = sessions_root(&harness_data_root());
            SessionLayout {
                sessions_root: root,
                project_name: state.project_name.clone(),
                session_id: state.session_id.clone(),
            }
        },
    )
}
