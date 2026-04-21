// End-to-end integration tests for POST /v1/sessions/adopt.
//
// Each test spawns a real daemon via `spawn_daemon_serve`, places a B-layout
// session directory on disk, and exercises the adopt HTTP endpoint with a
// `reqwest` client.  All three tests are `#[ignore]` (slow: spawn daemon).

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

use serde_json::{Value, json};
use tempfile::tempdir;
use tokio::runtime::Runtime;

use super::support::{
    DAEMON_HTTP_TIMEOUT, DAEMON_WAIT_INTERVAL, DAEMON_WAIT_TIMEOUT,
    current_daemon_endpoint_and_token, spawn_daemon_serve, wait_for_daemon_ready,
};

// Current schema version — must match `CURRENT_VERSION` in `session::types`.
const SCHEMA_VERSION: u32 = 9;

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| Runtime::new().expect("tokio runtime"))
}

/// Write a minimal B-layout session directory under `project_dir/<sid>/`.
///
/// `origin` is the value written to both `state.json::origin_path` and the
/// `.origin` marker — the adopter validates they match.
fn write_b_layout_session(project_dir: &Path, sid: &str, origin: &Path) -> PathBuf {
    let session_root = project_dir.join(sid);
    fs::create_dir_all(session_root.join("workspace")).unwrap();
    fs::create_dir_all(session_root.join("memory")).unwrap();

    let origin_str = origin.to_string_lossy();
    let state = json!({
        "schema_version": SCHEMA_VERSION,
        "state_version": 0,
        "session_id": sid,
        "project_name": project_dir.file_name().unwrap().to_string_lossy(),
        "origin_path": &*origin_str,
        "worktree_path": session_root.join("workspace").to_string_lossy().as_ref(),
        "shared_path": session_root.join("memory").to_string_lossy().as_ref(),
        "branch_ref": format!("harness/{sid}"),
        "title": "adopt test",
        "context": "integration",
        "status": "active",
        "created_at": "2026-04-20T12:34:56Z",
        "updated_at": "2026-04-20T12:34:56Z"
    });
    fs::write(
        session_root.join("state.json"),
        serde_json::to_vec_pretty(&state).unwrap(),
    )
    .unwrap();
    fs::write(session_root.join(".origin"), origin_str.as_bytes()).unwrap();
    session_root
}

/// POST to `/v1/sessions/adopt` and return `(http_status, response_body)`.
fn adopt(endpoint: &str, token: &str, session_root: &Path) -> (u16, Value) {
    let url = format!("{}/v1/sessions/adopt", endpoint.trim_end_matches('/'));
    let token = token.to_string();
    let body = json!({ "session_root": session_root.to_string_lossy() });

    let deadline = std::time::Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let client = reqwest::Client::new();
        let result = runtime().block_on(async {
            client
                .post(&url)
                .bearer_auth(token.clone())
                .json(&body)
                .timeout(DAEMON_HTTP_TIMEOUT)
                .send()
                .await
        });
        match result {
            Ok(response) => {
                let status = response.status().as_u16();
                let json = runtime()
                    .block_on(async { response.json::<Value>().await.expect("json body") });
                return (status, json);
            }
            Err(error) if error.is_connect() || error.is_timeout() => {
                assert!(
                    std::time::Instant::now() < deadline,
                    "adopt request timed out: {error}"
                );
                std::thread::sleep(DAEMON_WAIT_INTERVAL);
            }
            Err(error) => panic!("adopt request failed: {error}"),
        }
    }
}

/// List sessions via HTTP GET /v1/sessions and return the body.
fn list_sessions(endpoint: &str, token: &str) -> Value {
    let url = format!("{}/v1/sessions", endpoint.trim_end_matches('/'));
    let token = token.to_string();
    runtime().block_on(async {
        let client = reqwest::Client::new();
        client
            .get(&url)
            .bearer_auth(token)
            .timeout(Duration::from_secs(5))
            .send()
            .await
            .expect("list sessions request")
            .json::<Value>()
            .await
            .unwrap_or(Value::Null)
    })
}

// ---------------------------------------------------------------------------
// Test 1 — session placed inside the daemon's sessions root → 200, visible in
// list, `external_origin` is absent.
// ---------------------------------------------------------------------------

#[ignore]
#[test]
fn adopt_external_b_layout_session() {
    unsafe {
        std::env::remove_var("CLAUDE_SESSION_ID");
    }

    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&xdg).unwrap();

    // Fake project origin directory (does not need to be a git repo for adopt).
    let origin = tmp.path().join("src").join("kuma");
    fs::create_dir_all(&origin).unwrap();

    // Place the session under the daemon's canonical sessions root so it is
    // treated as an internal (non-external) session.
    let project_dir = xdg.join("harness").join("sessions").join("kuma");
    fs::create_dir_all(&project_dir).unwrap();
    let session_root = write_b_layout_session(&project_dir, "abc12345", &origin);

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    wait_for_daemon_ready(&home, &xdg);
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    let (status, body) = adopt(&endpoint, &token, &session_root);
    assert_eq!(status, 200, "adopt should return 200; body: {body}");
    assert_eq!(
        body["state"]["session_id"].as_str(),
        Some("abc12345"),
        "response must carry session_id"
    );
    assert!(
        body["state"]["external_origin"].is_null(),
        "internal session must have no external_origin; got: {}",
        body["state"]["external_origin"]
    );

    // Confirm the session appears in the daemon's in-memory session list via
    // GET /v1/sessions.
    let sessions = list_sessions(&endpoint, &token);
    let found_in_list = sessions
        .as_array()
        .map(|arr| {
            arr.iter().any(|entry| {
                entry["session_id"].as_str() == Some("abc12345")
                    || entry["state"]["session_id"].as_str() == Some("abc12345")
            })
        })
        .unwrap_or(false);
    assert!(
        found_in_list,
        "adopted session must appear in GET /v1/sessions; response: {sessions}"
    );

    // Also confirm the per-project `.active.json` registry was written.
    let active_registry = project_dir.join(".active.json");
    assert!(
        active_registry.exists(),
        "active registry must exist: {}",
        active_registry.display()
    );
    let registry_text = fs::read_to_string(&active_registry).expect("read active registry");
    assert!(
        registry_text.contains("abc12345"),
        "active registry must contain adopted session id; got: {registry_text}"
    );

    daemon.kill().expect("kill daemon");
}

// ---------------------------------------------------------------------------
// Test 2 — adopt once succeeds; second adopt returns 409 `already-attached`.
// ---------------------------------------------------------------------------

#[ignore]
#[test]
fn adopt_external_is_idempotent_with_409() {
    unsafe {
        std::env::remove_var("CLAUDE_SESSION_ID");
    }

    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&xdg).unwrap();

    let origin = tmp.path().join("src").join("kuma");
    fs::create_dir_all(&origin).unwrap();

    let project_dir = xdg.join("harness").join("sessions").join("kuma");
    fs::create_dir_all(&project_dir).unwrap();
    let session_root = write_b_layout_session(&project_dir, "abcdabcd", &origin);

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    wait_for_daemon_ready(&home, &xdg);
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    let (first_status, first_body) = adopt(&endpoint, &token, &session_root);
    assert_eq!(
        first_status, 200,
        "first adopt must succeed; body: {first_body}"
    );

    let (second_status, second_body) = adopt(&endpoint, &token, &session_root);
    assert_eq!(
        second_status, 409,
        "second adopt must return 409; body: {second_body}"
    );
    assert_eq!(
        second_body["error"].as_str(),
        Some("already-attached"),
        "error field must be 'already-attached'"
    );
    assert_eq!(
        second_body["session_id"].as_str(),
        Some("abcdabcd"),
        "session_id must be echoed in the conflict body"
    );

    daemon.kill().expect("kill daemon");
}

// ---------------------------------------------------------------------------
// Test 3 — session placed OUTSIDE the daemon's sessions root; adopt succeeds
// and `external_origin` is populated in the returned state.
// ---------------------------------------------------------------------------

#[ignore]
#[test]
fn adopt_external_outside_sessions_root_sets_flag() {
    unsafe {
        std::env::remove_var("CLAUDE_SESSION_ID");
    }

    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&xdg).unwrap();

    let origin = tmp.path().join("src").join("kuma");
    fs::create_dir_all(&origin).unwrap();

    // External project dir — lives completely outside `xdg/harness/sessions/`.
    let external_project = tmp.path().join("external-root").join("kuma");
    fs::create_dir_all(&external_project).unwrap();
    let session_root = write_b_layout_session(&external_project, "ffff0000", &origin);

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    wait_for_daemon_ready(&home, &xdg);
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    let (status, body) = adopt(&endpoint, &token, &session_root);
    assert_eq!(
        status, 200,
        "adopt of external session must return 200; body: {body}"
    );

    let external_origin = body["state"]["external_origin"].as_str();
    assert!(
        external_origin.is_some(),
        "external_origin must be populated for sessions outside the sessions root; body: {body}"
    );
    assert!(
        !external_origin.unwrap().is_empty(),
        "external_origin must be non-empty"
    );

    daemon.kill().expect("kill daemon");
}
