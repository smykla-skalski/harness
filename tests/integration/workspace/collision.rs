// Two project directories with the same basename ("project") must yield
// distinct project names in the sessions layout.  The second resolves to
// `project-<4hex>` so sessions never collide.

use harness_testkit::init_git_repo_with_seed;
use tempfile::tempdir;

use super::support::{
    layout_for_state, output_text, run_harness, spawn_daemon_serve, start_session_try,
    start_session_via_http, wait_for_daemon_ready,
};

/// Slow: spawns daemon.
#[ignore]
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

    // Verify .origin marker content for both sessions.
    // NOTE: .origin is written by WorktreeController::create in src/workspace/worktree.rs.
    // FIXME: marker may not be written on all code paths (see src/daemon/service/session_setup.rs).
    let layout_a = layout_for_state(&xdg, &state_a);
    let layout_b = layout_for_state(&xdg, &state_b);
    let origin_text_a =
        std::fs::read_to_string(layout_a.origin_marker()).expect("read .origin for session A");
    let origin_text_b =
        std::fs::read_to_string(layout_b.origin_marker()).expect("read .origin for session B");
    assert_eq!(
        origin_text_a.trim(),
        origin_a
            .canonicalize()
            .expect("canonicalize origin A")
            .to_str()
            .unwrap(),
        ".origin for session A must contain canonical origin path"
    );
    assert_eq!(
        origin_text_b.trim(),
        origin_b
            .canonicalize()
            .expect("canonicalize origin B")
            .to_str()
            .unwrap(),
        ".origin for session B must contain canonical origin path"
    );

    daemon.kill().expect("kill daemon");
}

/// Slow: spawns daemon.
#[ignore]
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
    let (status, _body) = start_session_try(&home, &xdg, &nonexistent, "col-bad-a1234567")
        .expect_err("start with nonexistent project_dir must fail");
    // Daemon returns 400 for all validation/workflow errors (see src/daemon/http/response.rs).
    assert_eq!(
        status, 400,
        "start with nonexistent project_dir must return 400; got {status}"
    );

    daemon.kill().expect("kill daemon");
}
