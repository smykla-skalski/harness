use super::*;

#[test]
fn serve_helpers_round_trip_smoke_covers_public_surface() {
    use std::sync::{Arc, Mutex, OnceLock};
    use std::time::Duration;

    use crate::daemon::codex_transport::CodexTransportKind;

    with_temp_project(|project| {
        let state = start_active_file_session(
            "daemon serve helpers smoke",
            "",
            project,
            Some("claude"),
            Some("daemon-serve-helpers"),
        )
        .expect("start session");

        append_project_ledger_entry(project);

        super::super::serve::validate_serve_config(&DaemonServeConfig {
            host: "127.0.0.1".into(),
            port: 0,
            poll_interval: Duration::from_secs(2),
            observe_interval: Duration::from_secs(5),
            sandboxed: false,
            codex_transport: CodexTransportKind::Stdio,
        })
        .expect("validate serve config");

        crate::daemon::state::ensure_daemon_dirs().expect("ensure daemon dirs");
        let db_path = state::daemon_root().join("harness.db");
        let standalone_db =
            super::super::serve::open_daemon_db(&db_path).expect("open standalone daemon db");
        drop(standalone_db);

        let db_slot = Arc::new(OnceLock::<Arc<Mutex<crate::daemon::db::DaemonDb>>>::new());
        let db = super::super::serve::open_and_publish_db(&db_slot).expect("publish daemon db");

        let (projects, sessions) = super::super::serve::discover_background_reconciliation_inputs()
            .expect("discover reconciliation inputs");
        assert_eq!(projects.len(), 1);
        assert!(
            sessions
                .iter()
                .any(|resolved| resolved.state.session_id == state.session_id),
            "expected session to be discoverable"
        );

        let mut result = crate::daemon::db::ReconcileResult::default();
        let candidates = super::super::serve::sync_background_projects_and_collect_candidates(
            &db,
            &projects,
            &sessions,
            &mut result,
        )
        .expect("sync background projects");
        assert_eq!(result.projects, 1);
        assert_eq!(candidates.len(), 1);

        let resolved = candidates
            .iter()
            .find(|resolved| resolved.state.session_id == state.session_id)
            .expect("resolved session");
        let prepared = super::super::serve::prepare_background_session_import(resolved)
            .expect("prepare session import");

        let db_guard = db.lock().expect("db lock");
        assert!(
            super::super::serve::session_import_required(&db_guard, resolved)
                .expect("session import required"),
            "file-backed session should require initial import"
        );
        assert_eq!(
            super::super::serve::prepared_session_import_required(&db_guard, &prepared),
            Some(true)
        );
        db_guard
            .apply_prepared_session_resync(&prepared)
            .expect("apply prepared import");
        assert!(
            !super::super::serve::session_import_required(&db_guard, resolved)
                .expect("session import no longer required"),
            "indexed session should not require re-import"
        );
        assert_eq!(
            super::super::serve::prepared_session_import_required(&db_guard, &prepared),
            Some(false)
        );
    });
}

#[test]
fn session_import_required_skips_matching_db_versions() {
    with_temp_project(|project| {
        let state = start_active_file_session(
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
        let state = start_active_file_session(
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
