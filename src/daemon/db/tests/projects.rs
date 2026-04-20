use super::*;

#[test]
fn sync_project_round_trip() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let name: String = db
        .conn
        .query_row(
            "SELECT name FROM projects WHERE project_id = ?1",
            [&project.project_id],
            |row| row.get(0),
        )
        .expect("query project");
    assert_eq!(name, "harness");
}

#[test]
fn sync_project_upsert_updates() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let mut project = sample_project();
    db.sync_project(&project).expect("first sync");

    project.name = "renamed".into();
    db.sync_project(&project).expect("second sync");

    let name: String = db
        .conn
        .query_row(
            "SELECT name FROM projects WHERE project_id = ?1",
            [&project.project_id],
            |row| row.get(0),
        )
        .expect("query project");
    assert_eq!(name, "renamed");
}

#[test]
fn project_summaries_group_worktrees_under_repository_root() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let repository = sample_repository_project("/tmp/kuma");
    let worktree = sample_worktree_project("/tmp/kuma", "/tmp/kuma/.claude/worktrees/feature-a");
    let repository_id = project_context_id(Path::new("/tmp/kuma")).expect("repository id");

    db.sync_project(&repository).expect("sync repository");
    db.sync_project(&worktree).expect("sync worktree");
    let state = sample_session_state_with_id("sess-worktree");
    db.sync_session(&worktree.project_id, &state)
        .expect("sync worktree session");

    let summaries = db.list_project_summaries().expect("project summaries");
    assert_eq!(summaries.len(), 1);
    let summary = &summaries[0];
    assert_eq!(summary.project_id, repository_id);
    assert_eq!(summary.name, "kuma");
    assert_eq!(summary.project_dir.as_deref(), Some("/tmp/kuma"));
    assert_eq!(summary.total_session_count, 1);
    assert_eq!(summary.worktrees.len(), 1);
    assert_eq!(summary.worktrees[0].name, "feature-a");
    assert_eq!(summary.worktrees[0].checkout_id, worktree.checkout_id);
    assert_eq!(
        summary.worktrees[0].checkout_root,
        "/tmp/kuma/.claude/worktrees/feature-a"
    );
    assert_eq!(summary.worktrees[0].total_session_count, 1);
}

#[test]
fn project_summaries_omit_projects_and_worktrees_without_sessions() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let repository = sample_repository_project("/tmp/kuma");
    let mut active_worktree =
        sample_worktree_project("/tmp/kuma", "/tmp/kuma/.claude/worktrees/feature-a");
    let mut idle_worktree =
        sample_worktree_project("/tmp/kuma", "/tmp/kuma/.claude/worktrees/feature-b");
    let mut idle_repository = sample_repository_project("/tmp/harness");
    active_worktree.context_root = "/tmp/data/projects/worktree-feature-a".into();
    idle_worktree.context_root = "/tmp/data/projects/worktree-feature-b".into();
    idle_repository.context_root = "/tmp/data/projects/repository-harness".into();

    db.sync_project(&repository).expect("sync repository");
    db.sync_project(&active_worktree)
        .expect("sync active worktree");
    db.sync_project(&idle_worktree).expect("sync idle worktree");
    db.sync_project(&idle_repository)
        .expect("sync idle repository");
    db.sync_session(
        &active_worktree.project_id,
        &sample_session_state_with_id("sess-worktree"),
    )
    .expect("sync worktree session");

    let summaries = db.list_project_summaries().expect("project summaries");

    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].name, "kuma");
    assert_eq!(summaries[0].worktrees.len(), 1);
    assert_eq!(summaries[0].worktrees[0].name, "feature-a");
}

#[test]
fn health_counts_omit_projects_and_worktrees_without_sessions() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let repository = sample_repository_project("/tmp/kuma");
    let mut active_worktree =
        sample_worktree_project("/tmp/kuma", "/tmp/kuma/.claude/worktrees/feature-a");
    let mut idle_worktree =
        sample_worktree_project("/tmp/kuma", "/tmp/kuma/.claude/worktrees/feature-b");
    let mut idle_repository = sample_repository_project("/tmp/harness");
    active_worktree.context_root = "/tmp/data/projects/worktree-feature-a".into();
    idle_worktree.context_root = "/tmp/data/projects/worktree-feature-b".into();
    idle_repository.context_root = "/tmp/data/projects/repository-harness".into();

    db.sync_project(&repository).expect("sync repository");
    db.sync_project(&active_worktree)
        .expect("sync active worktree");
    db.sync_project(&idle_worktree).expect("sync idle worktree");
    db.sync_project(&idle_repository)
        .expect("sync idle repository");
    db.sync_session(
        &active_worktree.project_id,
        &sample_session_state_with_id("sess-worktree"),
    )
    .expect("sync worktree session");

    let counts = db.health_counts().expect("health counts");

    assert_eq!(counts, (1, 1, 1));
}

#[test]
fn session_summaries_group_worktree_project_fields_under_repository_root() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let worktree = sample_worktree_project("/tmp/kuma", "/tmp/kuma/.claude/worktrees/feature-a");
    let repository_id = project_context_id(Path::new("/tmp/kuma")).expect("repository id");

    db.sync_project(&worktree).expect("sync worktree");
    let state = sample_session_state_with_id("sess-worktree");
    db.sync_session(&worktree.project_id, &state)
        .expect("sync worktree session");

    let summaries = db.list_session_summaries_full().expect("session summaries");
    assert_eq!(summaries.len(), 1);
    let summary = &summaries[0];
    assert_eq!(summary.project_id, repository_id);
    assert_eq!(summary.project_name, "kuma");
    assert_eq!(summary.project_dir.as_deref(), Some("/tmp/kuma"));
    assert!(
        summary
            .context_root
            .ends_with(&format!("projects/{repository_id}")),
        "unexpected repository context root: {}",
        summary.context_root
    );
    // workspace layout fields come from SessionState; sample state has empty paths
    assert_eq!(summary.worktree_path, "");
    assert_eq!(summary.shared_path, "");
    assert_eq!(summary.origin_path, "");
    assert_eq!(summary.branch_ref, "");
}
