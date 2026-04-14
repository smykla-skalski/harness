use super::*;

#[test]
fn session_import_required_skips_matching_db_versions() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon version skip",
            "",
            project,
            Some("claude"),
            Some("daemon-version-skip"),
        )
        .expect("start session");

        append_project_ledger_entry(project);
        let db_root = tempdir().expect("db root");
        let db =
            crate::daemon::db::DaemonDb::open(&db_root.path().join("harness.db")).expect("open db");
        let projects = crate::daemon::index::discover_projects().expect("discover projects");
        let sessions = crate::daemon::index::discover_sessions_for(&projects, true)
            .expect("discover sessions");
        db.reconcile_sessions(&projects, &sessions)
            .expect("reconcile sessions");
        let resolved = sessions
            .into_iter()
            .find(|resolved| resolved.state.session_id == state.session_id)
            .expect("resolved session");

        assert!(
            !session_import_required(&db, &resolved).expect("version check"),
            "already indexed session should not require prepare"
        );
    });
}

#[test]
fn session_import_required_detects_newer_file_versions() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon version refresh",
            "",
            project,
            Some("claude"),
            Some("daemon-version-refresh"),
        )
        .expect("start session");
        let leader_id = state.leader_id.clone().expect("leader id");

        append_project_ledger_entry(project);
        let db_root = tempdir().expect("db root");
        let db =
            crate::daemon::db::DaemonDb::open(&db_root.path().join("harness.db")).expect("open db");
        let projects = crate::daemon::index::discover_projects().expect("discover projects");
        let sessions = crate::daemon::index::discover_sessions_for(&projects, true)
            .expect("discover sessions");
        db.reconcile_sessions(&projects, &sessions)
            .expect("reconcile sessions");

        session_service::create_task(
            &state.session_id,
            "refresh daemon cache",
            None,
            crate::session::types::TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("create task");

        let refreshed_projects =
            crate::daemon::index::discover_projects().expect("rediscover projects");
        let refreshed_sessions =
            crate::daemon::index::discover_sessions_for(&refreshed_projects, true)
                .expect("rediscover sessions");
        let resolved = refreshed_sessions
            .into_iter()
            .find(|resolved| resolved.state.session_id == state.session_id)
            .expect("resolved session");

        assert!(
            session_import_required(&db, &resolved).expect("version check"),
            "newer file state should still prepare for import"
        );
    });
}
