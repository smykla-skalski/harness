use super::*;

#[test]
fn create_task_db_direct_writes_to_sqlite() {
    with_temp_project(|project| {
        let (db, state) = setup_db_only_session(project);
        let leader_id = state.leader_id.expect("leader id");

        let detail = create_task(
            &state.session_id,
            &TaskCreateRequest {
                actor: leader_id,
                title: "db-direct task".into(),
                context: None,
                severity: crate::session::types::TaskSeverity::Medium,
                suggested_fix: None,
            },
            Some(&db),
        )
        .expect("create task via db");

        assert_eq!(detail.tasks.len(), 1);
        assert_eq!(detail.tasks[0].title, "db-direct task");

        let db_state = db
            .load_session_state(&state.session_id)
            .expect("load state")
            .expect("state present");
        assert_eq!(db_state.tasks.len(), 1);
    });
}

#[test]
fn join_session_direct_rejects_leader_role() {
    with_temp_project(|project| {
        use crate::daemon::protocol::{SessionJoinRequest, SessionStartRequest};

        let db = setup_db_with_project(project);
        start_session_direct(
            &SessionStartRequest {
                title: "leader join denied".into(),
                context: "daemon joins cannot claim leader".into(),
                runtime: "claude".into(),
                session_id: Some("leader-join-denied".into()),
                project_dir: project.to_string_lossy().into(),
            },
            Some(&db),
        )
        .expect("start session");

        let result =
            temp_env::with_vars([("CODEX_SESSION_ID", Some("leader-join-worker"))], || {
                join_session_direct(
                    "leader-join-denied",
                    &SessionJoinRequest {
                        runtime: "codex".into(),
                        role: SessionRole::Leader,
                        capabilities: vec![],
                        name: Some("spoofed leader".into()),
                        project_dir: project.to_string_lossy().into(),
                        persona: None,
                    },
                    Some(&db),
                )
            });

        let error = result.expect_err("leader join should be rejected");
        assert_eq!(error.code(), "KSRCLI092");
        assert!(error.message().contains("leader"));
    });
}

#[test]
fn end_session_db_direct_marks_inactive() {
    with_temp_project(|project| {
        let (db, state) = setup_db_only_session(project);
        let leader_id = state.leader_id.clone().expect("leader id");
        let worker_id = join_db_codex_worker(&db, &state, project, "db-end-worker");

        let detail = end_session(
            &state.session_id,
            &SessionEndRequest { actor: leader_id },
            Some(&db),
        )
        .expect("end session via db");

        assert_eq!(detail.session.status, SessionStatus::Ended);
        assert_eq!(detail.session.metrics.active_agent_count, 0);
        assert!(detail.session.leader_id.is_none());
        assert!(
            detail.agents.is_empty(),
            "ended sessions should not expose dead agents"
        );
        assert_eq!(detail.signals.len(), 2);
        assert!(
            detail
                .signals
                .iter()
                .any(|signal| signal.agent_id == worker_id)
        );
        assert!(
            detail
                .signals
                .iter()
                .all(|signal| signal.signal.command == "abort")
        );

        let db_state = db
            .load_session_state(&state.session_id)
            .expect("load state")
            .expect("state present");
        assert_eq!(db_state.status, SessionStatus::Ended);
        assert_eq!(
            db.load_signals(&state.session_id).expect("signals").len(),
            2
        );
    });
}

#[test]
fn remove_agent_db_direct_sends_abort_signal() {
    with_temp_project(|project| {
        let (db, state) = setup_db_only_session(project);
        let leader_id = state.leader_id.clone().expect("leader id");
        let worker_id = join_db_codex_worker(&db, &state, project, "db-remove-worker");

        let detail = remove_agent(
            &state.session_id,
            &worker_id,
            &AgentRemoveRequest { actor: leader_id },
            Some(&db),
        )
        .expect("remove via db");

        assert!(
            detail
                .agents
                .iter()
                .all(|agent| agent.agent_id != worker_id),
            "removed agents should disappear from session detail"
        );
        assert_eq!(detail.signals.len(), 1);
        assert_eq!(detail.signals[0].agent_id, worker_id);
        assert_eq!(detail.signals[0].signal.command, "abort");
        assert_eq!(detail.signals[0].status, SessionSignalStatus::Pending);
    });
}

#[test]
fn start_session_db_direct_creates_in_sqlite() {
    with_temp_project(|project| {
        use crate::daemon::protocol::SessionStartRequest;

        let db = setup_db_with_project(project);

        let state = start_session_direct(
            &SessionStartRequest {
                title: "db-direct start session".into(),
                context: "db-direct start".into(),
                runtime: "claude".into(),
                session_id: Some("daemon-start-1".into()),
                project_dir: project.to_string_lossy().into(),
            },
            Some(&db),
        )
        .expect("start session via db");

        assert_eq!(state.context, "db-direct start");
        assert!(state.leader_id.is_some());
        assert_eq!(state.agents.len(), 1);

        let db_state = db
            .load_session_state("daemon-start-1")
            .expect("load")
            .expect("present");
        assert_eq!(db_state.context, "db-direct start");
    });
}

#[test]
fn start_session_db_direct_registers_fresh_project_for_discovery() {
    with_temp_project(|project| {
        use crate::daemon::protocol::SessionStartRequest;

        let db = crate::daemon::db::DaemonDb::open_in_memory().expect("open db");
        let canonical_project = project.canonicalize().expect("canonicalize project");

        let state = start_session_direct(
            &SessionStartRequest {
                title: "fresh-project start session".into(),
                context: "fresh-project start".into(),
                runtime: "claude".into(),
                session_id: Some("daemon-start-fresh".into()),
                project_dir: canonical_project.to_string_lossy().into_owned(),
            },
            Some(&db),
        )
        .expect("start session via db for fresh project");

        let project_id = db
            .ensure_project_for_dir(&canonical_project.to_string_lossy())
            .expect("project registered in db");
        assert_eq!(
            db.project_id_for_session(&state.session_id)
                .expect("lookup session project id")
                .as_deref(),
            Some(project_id.as_str())
        );

        let context_root = project_context_dir(project);
        assert!(context_root.join("project-origin.json").is_file());

        let discovered = index::discover_projects().expect("discover projects");
        assert_eq!(discovered.len(), 1);
        assert_eq!(
            discovered[0].project_dir.as_deref(),
            Some(canonical_project.as_path())
        );
    });
}

#[test]
fn join_session_db_direct_adds_agent() {
    with_temp_project(|project| {
        use crate::daemon::protocol::{SessionJoinRequest, SessionStartRequest};

        let db = setup_db_with_project(project);

        start_session_direct(
            &SessionStartRequest {
                title: "join test session".into(),
                context: "join test".into(),
                runtime: "claude".into(),
                session_id: Some("daemon-join-1".into()),
                project_dir: project.to_string_lossy().into(),
            },
            Some(&db),
        )
        .expect("start session");

        let joined = join_session_direct(
            "daemon-join-1",
            &SessionJoinRequest {
                runtime: "codex".into(),
                role: SessionRole::Worker,
                capabilities: vec![],
                name: None,
                project_dir: project.to_string_lossy().into(),
                persona: None,
            },
            Some(&db),
        )
        .expect("join session via db");

        assert_eq!(joined.agents.len(), 2);

        let db_state = db
            .load_session_state("daemon-join-1")
            .expect("load")
            .expect("present");
        assert_eq!(db_state.agents.len(), 2);
    });
}
