// Two concurrent sessions against the same origin must yield distinct
// workspaces, distinct branches, and non-overlapping .active.json entries.

use harness_testkit::init_git_repo_with_seed;
use tempfile::tempdir;

use super::support::{
    delete_session_via_http, git_branches_matching, output_text, run_harness, spawn_daemon_serve,
    start_session_via_http, wait_for_daemon_ready,
};

#[test]
fn two_sessions_same_origin_get_distinct_workspaces() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo_with_seed(&project);

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    wait_for_daemon_ready(&home, &xdg);

    let state_a = start_session_via_http(&home, &xdg, &project, "wk-par-a1234567");
    let state_b = start_session_via_http(&home, &xdg, &project, "wk-par-b1234567");

    // Session ids must be distinct.
    assert_ne!(
        state_a.session_id, state_b.session_id,
        "parallel sessions must have distinct ids"
    );

    // Both worktrees must exist and be at different paths.
    assert!(
        state_a.worktree_path.exists(),
        "worktree A must exist: {}",
        state_a.worktree_path.display()
    );
    assert!(
        state_b.worktree_path.exists(),
        "worktree B must exist: {}",
        state_b.worktree_path.display()
    );
    assert_ne!(
        state_a.worktree_path, state_b.worktree_path,
        "parallel sessions must have distinct worktree paths"
    );

    // Each session has its own memory dir.
    assert_ne!(
        state_a.shared_path, state_b.shared_path,
        "parallel sessions must have distinct shared paths"
    );

    // Both branches must be present in the origin repo.
    let branches = git_branches_matching(&project, "harness/");
    assert!(
        branches.contains(&"harness/wk-par-a1234567".to_string()),
        "branch A must exist; found: {branches:?}"
    );
    assert!(
        branches.contains(&"harness/wk-par-b1234567".to_string()),
        "branch B must exist; found: {branches:?}"
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
        session_ids.contains(&"wk-par-a1234567"),
        "session A must appear in list; found: {session_ids:?}"
    );
    assert!(
        session_ids.contains(&"wk-par-b1234567"),
        "session B must appear in list; found: {session_ids:?}"
    );

    daemon.kill().expect("kill daemon");
}

#[test]
fn deleting_one_session_leaves_other_intact() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo_with_seed(&project);

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    wait_for_daemon_ready(&home, &xdg);

    let state_a = start_session_via_http(&home, &xdg, &project, "wk-del-a7654321");
    let state_b = start_session_via_http(&home, &xdg, &project, "wk-del-b7654321");

    // Delete only session A.
    let http_status = delete_session_via_http(&home, &xdg, "wk-del-a7654321");
    assert_eq!(http_status, 204, "DELETE A must return 204");

    // Session A's worktree is gone.
    assert!(
        !state_a.worktree_path.exists(),
        "worktree A must be gone: {}",
        state_a.worktree_path.display()
    );

    // Session B's worktree is still present.
    assert!(
        state_b.worktree_path.exists(),
        "worktree B must still exist after A is deleted: {}",
        state_b.worktree_path.display()
    );

    // Branch A gone, branch B present.
    let branches = git_branches_matching(&project, "harness/");
    assert!(
        !branches.contains(&"harness/wk-del-a7654321".to_string()),
        "branch A must be deleted; found: {branches:?}"
    );
    assert!(
        branches.contains(&"harness/wk-del-b7654321".to_string()),
        "branch B must still exist; found: {branches:?}"
    );

    // session list no longer shows A.
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
        !session_ids.contains(&"wk-del-a7654321"),
        "session A must not appear in list after delete; found: {session_ids:?}"
    );
    assert!(
        session_ids.contains(&"wk-del-b7654321"),
        "session B must still appear in list; found: {session_ids:?}"
    );

    daemon.kill().expect("kill daemon");
}

#[test]
fn active_json_tracks_each_session() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo_with_seed(&project);

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    wait_for_daemon_ready(&home, &xdg);

    let state_a = start_session_via_http(&home, &xdg, &project, "wk-act-a2468ace");
    let state_b = start_session_via_http(&home, &xdg, &project, "wk-act-b2468ace");

    // Derive active registry path for each session from its own state.
    use harness::workspace::harness_data_root;
    use harness::workspace::layout::{SessionLayout, sessions_root};

    let (active_a, active_b) = temp_env::with_vars(
        [("XDG_DATA_HOME", Some(xdg.to_str().expect("utf8")))],
        || {
            let sessions = sessions_root(&harness_data_root());
            let path_a = SessionLayout {
                sessions_root: sessions.clone(),
                project_name: state_a.project_name.clone(),
                session_id: state_a.session_id.clone(),
            }
            .active_registry();
            let path_b = SessionLayout {
                sessions_root: sessions,
                project_name: state_b.project_name.clone(),
                session_id: state_b.session_id.clone(),
            }
            .active_registry();
            (path_a, path_b)
        },
    );

    // Session A's registry must list A.
    assert!(
        active_a.exists(),
        ".active.json for session A must exist: {}",
        active_a.display()
    );
    let active_text_a = std::fs::read_to_string(&active_a).expect("read .active.json A");
    assert!(
        active_text_a.contains("wk-act-a2468ace"),
        ".active.json A must contain session A; content: {active_text_a}"
    );

    // Session B's registry must list B.
    assert!(
        active_b.exists(),
        ".active.json for session B must exist: {}",
        active_b.display()
    );
    let active_text_b = std::fs::read_to_string(&active_b).expect("read .active.json B");
    assert!(
        active_text_b.contains("wk-act-b2468ace"),
        ".active.json B must contain session B; content: {active_text_b}"
    );

    daemon.kill().expect("kill daemon");
}
