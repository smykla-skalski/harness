use super::*;

#[test]
fn mark_session_inactive_clears_active_flag() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    let state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let active_before: i32 = db
        .conn
        .query_row(
            "SELECT is_active FROM sessions WHERE session_id = ?1",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("query active");
    assert_eq!(active_before, 1);

    db.mark_session_inactive(&state.session_id)
        .expect("mark inactive");

    let active_after: i32 = db
        .conn
        .query_row(
            "SELECT is_active FROM sessions WHERE session_id = ?1",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("query active");
    assert_eq!(active_after, 0);
}

#[test]
fn project_id_for_session_returns_correct_id() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    let state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let found = db
        .project_id_for_session(&state.session_id)
        .expect("lookup");
    assert_eq!(found.as_deref(), Some("project-abc123"));
}

#[test]
fn project_id_for_session_returns_none_for_missing() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let found = db.project_id_for_session("nonexistent").expect("lookup");
    assert!(found.is_none());
}

#[test]
fn ensure_project_for_dir_creates_and_returns_id() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let found = db
        .ensure_project_for_dir("/tmp/harness")
        .expect("ensure project");
    assert_eq!(found, "project-abc123");
}

#[test]
fn ensure_project_for_dir_matches_context_root() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let found = db
        .ensure_project_for_dir("/tmp/data/projects/project-abc123")
        .expect("ensure by context root");
    assert_eq!(found, "project-abc123");
}

#[test]
fn ensure_project_for_dir_returns_error_for_unknown() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let result = db.ensure_project_for_dir("/nonexistent/path");
    assert!(result.is_err());
}

#[test]
fn load_session_state_for_mutation_returns_mutable_state() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    let state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let loaded = db
        .load_session_state_for_mutation(&state.session_id)
        .expect("load")
        .expect("present");
    assert_eq!(loaded.session_id, "sess-test-1");
    assert_eq!(loaded.agents.len(), 1);
    assert_eq!(loaded.tasks.len(), 1);
}

#[test]
fn load_session_state_for_mutation_returns_none_for_missing() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let loaded = db
        .load_session_state_for_mutation("nonexistent")
        .expect("load");
    assert!(loaded.is_none());
}

#[test]
fn save_session_state_persists_changes() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    let mut state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("initial sync");

    state.context = "updated context".into();
    state.state_version = 2;
    db.save_session_state(&project.project_id, &state)
        .expect("save");

    let reloaded = db
        .load_session_state(&state.session_id)
        .expect("load")
        .expect("present");
    assert_eq!(reloaded.context, "updated context");
    assert_eq!(reloaded.state_version, 2);
}

#[test]
fn create_session_record_inserts_active_session() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let state = sample_session_state();
    db.create_session_record(&project.project_id, &state)
        .expect("create");

    let loaded = db
        .load_session_state(&state.session_id)
        .expect("load")
        .expect("present");
    assert_eq!(loaded.session_id, "sess-test-1");

    let is_active: i32 = db
        .conn
        .query_row(
            "SELECT is_active FROM sessions WHERE session_id = ?1",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("query active");
    assert_eq!(is_active, 1);
}
