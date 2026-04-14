use super::*;

#[test]
fn reconcile_imports_new_session() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    let resolved = sample_resolved_session(&project, "new-sess", 1);

    let result = db
        .reconcile_sessions(&[project], &[resolved])
        .expect("reconcile");
    assert_eq!(result.projects, 1);
    assert_eq!(result.sessions_imported, 1);
    assert_eq!(result.sessions_skipped, 0);

    let loaded = db
        .load_session_state("new-sess")
        .expect("load")
        .expect("present");
    assert_eq!(loaded.state_version, 1);
}

#[test]
fn reconcile_skips_session_with_equal_db_version() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let mut state = sample_session_state();
    state.state_version = 3;
    state.context = "daemon version".into();
    db.sync_session(&project.project_id, &state).expect("sync");

    let mut file_state = sample_session_state();
    file_state.state_version = 3;
    file_state.context = "file version".into();
    let resolved = daemon_index::ResolvedSession {
        project: project.clone(),
        state: file_state,
    };

    let result = db
        .reconcile_sessions(&[project], &[resolved])
        .expect("reconcile");
    assert_eq!(result.sessions_imported, 0);
    assert_eq!(result.sessions_skipped, 1);

    let loaded = db
        .load_session_state("sess-test-1")
        .expect("load")
        .expect("present");
    assert_eq!(loaded.context, "daemon version");
}

#[test]
fn reconcile_skips_session_with_higher_db_version() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let mut state = sample_session_state();
    state.state_version = 5;
    state.context = "daemon mutated".into();
    db.sync_session(&project.project_id, &state).expect("sync");

    let mut file_state = sample_session_state();
    file_state.state_version = 2;
    file_state.context = "stale file".into();
    let resolved = daemon_index::ResolvedSession {
        project: project.clone(),
        state: file_state,
    };

    let result = db
        .reconcile_sessions(&[project], &[resolved])
        .expect("reconcile");
    assert_eq!(result.sessions_imported, 0);
    assert_eq!(result.sessions_skipped, 1);

    let loaded = db
        .load_session_state("sess-test-1")
        .expect("load")
        .expect("present");
    assert_eq!(loaded.context, "daemon mutated");
    assert_eq!(loaded.state_version, 5);
}

#[test]
fn reconcile_imports_session_with_higher_file_version() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let mut state = sample_session_state();
    state.state_version = 2;
    state.context = "old db".into();
    db.sync_session(&project.project_id, &state).expect("sync");

    let mut file_state = sample_session_state();
    file_state.state_version = 5;
    file_state.context = "updated file".into();
    let resolved = daemon_index::ResolvedSession {
        project: project.clone(),
        state: file_state,
    };

    let result = db
        .reconcile_sessions(&[project], &[resolved])
        .expect("reconcile");
    assert_eq!(result.sessions_imported, 1);
    assert_eq!(result.sessions_skipped, 0);

    let loaded = db
        .load_session_state("sess-test-1")
        .expect("load")
        .expect("present");
    assert_eq!(loaded.context, "updated file");
    assert_eq!(loaded.state_version, 5);
}

#[test]
fn reconcile_preserves_daemon_only_sessions() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let mut daemon_session = sample_session_state();
    daemon_session.session_id = "daemon-only".into();
    daemon_session.state_version = 3;
    daemon_session.context = "daemon created".into();
    db.sync_session(&project.project_id, &daemon_session)
        .expect("sync daemon session");

    // Reconcile with a file that has a DIFFERENT session (not daemon-only)
    let file_session = sample_resolved_session(&project, "file-only", 1);

    let result = db
        .reconcile_sessions(&[project], &[file_session])
        .expect("reconcile");
    assert_eq!(result.sessions_imported, 1);

    // daemon-only session must still exist
    let loaded = db
        .load_session_state("daemon-only")
        .expect("load")
        .expect("present");
    assert_eq!(loaded.context, "daemon created");
}

#[test]
fn session_state_version_returns_none_when_missing() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let version = db.session_state_version("nonexistent").expect("query");
    assert_eq!(version, None);
}

#[test]
fn session_state_version_returns_version_when_present() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let mut state = sample_session_state();
    state.state_version = 7;
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let version = db.session_state_version(&state.session_id).expect("query");
    assert_eq!(version, Some(7));
}
