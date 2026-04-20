// Session workspace lifecycle: start -> list -> status -> delete.
//
// Verifies that the daemon creates a git worktree, memory directory, and
// state.json at the new `<sessions_root>/<project>/<sid>/` layout, and that
// DELETE /v1/sessions/<id> tears all of that down cleanly.

use harness_testkit::{init_git_repo_with_branches, init_git_repo_with_seed};
use tempfile::tempdir;

use super::support::{
    delete_session_via_http, git_branches_matching, git_head_sha, layout_for_state, output_text,
    run_harness, spawn_daemon_serve, start_session_via_http, start_session_with_base_ref,
    wait_for_daemon_ready,
};

/// Slow: spawns daemon.
#[ignore]
#[test]
fn session_start_creates_workspace_layout() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo_with_seed(&project);

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    wait_for_daemon_ready(&home, &xdg);

    let state = start_session_via_http(&home, &xdg, &project, "wk-lifecycle-1");

    // Session id must be 8-char alphanumeric (new format from ids::new_session_id).
    assert_eq!(
        state.session_id, "wk-lifecycle-1",
        "explicit session id must be honoured"
    );

    // Check that project_name is derived from the project dir basename.
    assert_eq!(state.project_name, "project");
    assert_eq!(state.branch_ref, "harness/wk-lifecycle-1");

    // Verify state.worktree_path points inside the sessions root.
    assert!(
        !state.worktree_path.as_os_str().is_empty(),
        "worktree_path must be populated by daemon"
    );
    assert!(
        state.worktree_path.exists(),
        "worktree must exist on disk: {}",
        state.worktree_path.display()
    );
    assert!(
        state.shared_path.exists(),
        "memory dir must exist on disk: {}",
        state.shared_path.display()
    );

    // Derive the layout the same way the daemon does.
    let layout = layout_for_state(&xdg, &state);

    // state.json must exist.
    assert!(
        layout.state_file().exists(),
        "state.json must exist: {}",
        layout.state_file().display()
    );

    // .locks dir must exist.
    assert!(
        layout.locks_dir().exists(),
        ".locks dir must exist: {}",
        layout.locks_dir().display()
    );

    // .active.json must list the session.
    let active_path = layout.active_registry();
    assert!(
        active_path.exists(),
        ".active.json must exist: {}",
        active_path.display()
    );
    let active_text = std::fs::read_to_string(&active_path).expect("read .active.json");
    assert!(
        active_text.contains("wk-lifecycle-1"),
        ".active.json must contain session id; content: {active_text}"
    );

    // .origin must exist.
    assert!(
        layout.origin_marker().exists(),
        ".origin marker must exist: {}",
        layout.origin_marker().display()
    );

    daemon.kill().expect("kill daemon");
}

/// Slow: spawns daemon.
#[ignore]
#[test]
fn session_list_shows_session_id() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo_with_seed(&project);

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    wait_for_daemon_ready(&home, &xdg);
    // branch_ref is returned directly from the session start response and also
    // forwarded by src/session/service/conversions.rs into CLI list/status output.
    let state = start_session_via_http(&home, &xdg, &project, "wk-list-1");
    assert_eq!(
        state.branch_ref, "harness/wk-list-1",
        "session start response must carry branch_ref"
    );

    let list_out = run_harness(&home, &xdg, &["session", "list"]);
    assert!(
        list_out.status.success(),
        "session list failed: {}",
        output_text(&list_out)
    );
    let list_text = String::from_utf8_lossy(&list_out.stdout);
    assert!(
        list_text.contains("wk-list-1"),
        "list output must contain session id; got: {list_text}"
    );

    daemon.kill().expect("kill daemon");
}

/// Slow: spawns daemon.
#[ignore]
#[test]
fn session_status_shows_session_id_and_title() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo_with_seed(&project);

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    wait_for_daemon_ready(&home, &xdg);
    let project_arg = project.to_str().expect("utf8");
    start_session_via_http(&home, &xdg, &project, "wk-status-1");

    let status_out = run_harness(
        &home,
        &xdg,
        &[
            "session",
            "status",
            "wk-status-1",
            "--project-dir",
            project_arg,
        ],
    );
    assert!(
        status_out.status.success(),
        "session status failed: {}",
        output_text(&status_out)
    );
    let status_text = String::from_utf8_lossy(&status_out.stdout);
    assert!(
        status_text.contains("wk-status-1"),
        "status must contain session id; got: {status_text}"
    );

    daemon.kill().expect("kill daemon");
}

/// Slow: spawns daemon.
#[ignore]
#[test]
fn session_delete_removes_worktree_branch_and_state_files() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo_with_seed(&project);

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    wait_for_daemon_ready(&home, &xdg);

    // Fields below come from the raw HTTP start response; CLI conversions also
    // forward them.
    let state = start_session_via_http(&home, &xdg, &project, "wk-delete-1");
    let worktree_path = state.worktree_path.clone();
    let layout = layout_for_state(&xdg, &state);

    assert!(worktree_path.exists(), "worktree must exist before delete");
    assert!(
        layout.state_file().exists(),
        "state.json must exist before delete"
    );

    let http_status = delete_session_via_http(&home, &xdg, "wk-delete-1");
    assert_eq!(http_status, 204, "DELETE must return 204");

    // Worktree must be gone.
    assert!(
        !worktree_path.exists(),
        "worktree must be gone after delete: {}",
        worktree_path.display()
    );

    // Git branch must be gone.
    let branches = git_branches_matching(&project, "harness/");
    assert!(
        !branches.iter().any(|b| b == "harness/wk-delete-1"),
        "branch harness/wk-delete-1 must be deleted; found: {branches:?}"
    );

    // state.json (session root) must be gone.
    assert!(
        !layout.session_root().exists(),
        "session root must be removed: {}",
        layout.session_root().display()
    );

    // .active.json must not list the deleted session.
    if layout.active_registry().exists() {
        let active_text =
            std::fs::read_to_string(layout.active_registry()).expect("read .active.json");
        assert!(
            !active_text.contains("wk-delete-1"),
            ".active.json must not contain deleted session; content: {active_text}"
        );
    }

    daemon.kill().expect("kill daemon");
}

/// Slow: spawns daemon; verifies that base_ref routes worktree to the named branch tip.
#[ignore]
#[test]
fn session_start_with_base_ref_routes_to_requested_branch() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo_with_branches(&project, "release");

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    wait_for_daemon_ready(&home, &xdg);

    let state = start_session_with_base_ref(&home, &xdg, &project, "wk-base-ref-1", "release");

    assert!(
        state.branch_ref.starts_with("harness/"),
        "branch_ref must be a harness/ branch; got {}",
        state.branch_ref
    );

    // The per-session worktree must be on the 'release' tip.
    let expected_tip = git_head_sha(&project, "release");
    let actual_tip = git_head_sha(&project, &state.branch_ref);
    assert_eq!(
        expected_tip, actual_tip,
        "harness/<sid> branch must point at the release tip"
    );

    daemon.kill().expect("kill daemon");
}
