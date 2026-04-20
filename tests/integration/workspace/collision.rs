// Two project directories with the same basename ("project") must yield
// distinct project names in the sessions layout.  The second resolves to
// `project-<4hex>` so sessions never collide.

use harness_testkit::init_git_repo_with_seed;
use tempfile::tempdir;

use super::support::{
    output_text, run_harness, spawn_daemon_serve, start_session_via_http, wait_for_daemon_ready,
};

#[test]
fn two_origins_same_basename_get_distinct_project_names() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");

    // Two distinct canonical paths that share the basename "project".
    let origin_a = tmp.path().join("tree-a").join("project");
    let origin_b = tmp.path().join("tree-b").join("project");

    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo_with_seed(&origin_a);
    init_git_repo_with_seed(&origin_b);

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    wait_for_daemon_ready(&home, &xdg);

    // Start one session from each origin.
    let state_a = start_session_via_http(&home, &xdg, &origin_a, "col-same-a1234567");
    let state_b = start_session_via_http(&home, &xdg, &origin_b, "col-same-b1234567");

    // Project names must differ even though both basenames are "project".
    assert_ne!(
        state_a.project_name, state_b.project_name,
        "distinct canonical origins with same basename must get distinct project names"
    );

    // The first to arrive keeps the plain basename.
    assert_eq!(
        state_a.project_name, "project",
        "first origin must use plain basename"
    );

    // The second gets a hash-suffixed variant.
    assert!(
        state_b.project_name.starts_with("project-"),
        "second origin must get a hashed suffix; got: {:?}",
        state_b.project_name
    );
    assert_eq!(
        state_b.project_name.len(),
        "project-".len() + 4,
        "hash suffix must be 4 hex chars"
    );

    // Both sessions must appear in the list.
    let list_out = run_harness(&home, &xdg, &["session", "list", "--json"]);
    assert!(
        list_out.status.success(),
        "session list failed: {}",
        output_text(&list_out)
    );
    let sessions: Vec<serde_json::Value> =
        serde_json::from_slice(&list_out.stdout).expect("parse list");
    let session_ids: Vec<&str> = sessions
        .iter()
        .filter_map(|s| s["session_id"].as_str())
        .collect();
    assert!(
        session_ids.contains(&"col-same-a1234567"),
        "session A must appear in list; found: {session_ids:?}"
    );
    assert!(
        session_ids.contains(&"col-same-b1234567"),
        "session B must appear in list; found: {session_ids:?}"
    );

    daemon.kill().expect("kill daemon");
}

#[test]
fn invalid_project_dir_returns_error_status() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");

    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    wait_for_daemon_ready(&home, &xdg);

    // A path that does not exist on the filesystem cannot be canonicalized.
    let nonexistent = tmp.path().join("does-not-exist").join("project");
    let status = start_session_raw_status(&home, &xdg, &nonexistent, "col-bad-a1234567");
    assert_ne!(
        status, 200,
        "start with nonexistent project_dir must fail; got {status}"
    );

    daemon.kill().expect("kill daemon");
}

/// Returns the raw HTTP status without panicking, for negative tests.
fn start_session_raw_status(
    home: &std::path::Path,
    xdg: &std::path::Path,
    project_dir: &std::path::Path,
    session_id: &str,
) -> u16 {
    use std::thread;
    use std::time::Instant;

    use serde_json::json;
    use tokio::runtime::Runtime;

    use super::support::{
        DAEMON_HTTP_TIMEOUT, DAEMON_WAIT_INTERVAL, DAEMON_WAIT_TIMEOUT,
        current_daemon_endpoint_and_token,
    };

    let runtime = Runtime::new().expect("runtime");
    let project_arg = project_dir.to_str().expect("utf8 project path");
    let body = json!({
        "title": "collision negative test",
        "context": "bad project_dir",
        "runtime": "codex",
        "session_id": session_id,
        "project_dir": project_arg,
    });

    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let (endpoint, token) = current_daemon_endpoint_and_token(home, xdg);
        let url = format!("{}/v1/sessions", endpoint.trim_end_matches('/'));
        let client = reqwest::Client::new();
        let result = runtime.block_on(async {
            client
                .post(&url)
                .bearer_auth(&token)
                .json(&body)
                .timeout(DAEMON_HTTP_TIMEOUT)
                .send()
                .await
        });
        match result {
            Ok(response) => return response.status().as_u16(),
            Err(error) if error.is_connect() || error.is_timeout() => {
                assert!(
                    Instant::now() < deadline,
                    "daemon connection timed out: {error}"
                );
                thread::sleep(DAEMON_WAIT_INTERVAL);
            }
            Err(error) => panic!("request failed: {error}"),
        }
    }
}
