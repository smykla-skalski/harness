use super::super::*;

#[test]
fn remove_agent_async_direct_sends_abort_signal() {
    with_temp_project(|project| {
        temp_env::with_var("CODEX_SESSION_ID", Some("async-remove-worker"), || {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let db_path = project
                    .parent()
                    .expect("project parent")
                    .join("daemon.sqlite");
                let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                    .await
                    .expect("open async daemon db");
                let state = start_direct_session_async(
                    &async_db,
                    project,
                    "b008af80-54bd-5d3d-aef2-a6cd524b8684",
                    "async remove session",
                    "async remove",
                    None,
                )
                .await;
                let leader_id = state.leader_id.clone().expect("leader id");
                let joined = join_session_direct_async(
                    "b008af80-54bd-5d3d-aef2-a6cd524b8684",
                    &crate::daemon::protocol::SessionJoinRequest {
                        runtime: "codex".into(),
                        role: SessionRole::Worker,
                        fallback_role: None,
                        capabilities: vec![],
                        name: None,
                        project_dir: project.to_string_lossy().into(),
                        persona: None,
                    },
                    &async_db,
                )
                .await
                .expect("join session");
                let worker_id = joined
                    .agents
                    .keys()
                    .find(|agent_id| agent_id.starts_with("codex-"))
                    .expect("worker id")
                    .clone();

                let detail = remove_agent_async(
                    "b008af80-54bd-5d3d-aef2-a6cd524b8684",
                    &worker_id,
                    &AgentRemoveRequest { actor: leader_id },
                    &async_db,
                )
                .await
                .expect("remove via async db");

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
        });
    });
}

#[test]
fn end_session_async_direct_marks_inactive() {
    with_temp_project(|project| {
        temp_env::with_var("CODEX_SESSION_ID", Some("async-end-worker"), || {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let db_path = project
                    .parent()
                    .expect("project parent")
                    .join("daemon.sqlite");
                let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                    .await
                    .expect("open async daemon db");
                let state = start_direct_session_async(
                    &async_db,
                    project,
                    "19bd7483-41f5-53fa-8391-c65b30390c1d",
                    "async end session",
                    "async end",
                    None,
                )
                .await;
                let leader_id = state.leader_id.clone().expect("leader id");
                let joined = join_session_direct_async(
                    "19bd7483-41f5-53fa-8391-c65b30390c1d",
                    &crate::daemon::protocol::SessionJoinRequest {
                        runtime: "codex".into(),
                        role: SessionRole::Worker,
                        fallback_role: None,
                        capabilities: vec![],
                        name: None,
                        project_dir: project.to_string_lossy().into(),
                        persona: None,
                    },
                    &async_db,
                )
                .await
                .expect("join session");
                let worker_id = joined
                    .agents
                    .keys()
                    .find(|agent_id| agent_id.starts_with("codex-"))
                    .expect("worker id")
                    .clone();

                let detail = end_session_async(
                    "19bd7483-41f5-53fa-8391-c65b30390c1d",
                    &SessionEndRequest { actor: leader_id },
                    &async_db,
                )
                .await
                .expect("end session via async db");

                assert_eq!(detail.session.status, SessionStatus::Ended);
                assert_eq!(detail.session.metrics.active_agent_count, 0);
                assert!(detail.session.leader_id.is_none());
                assert!(detail.agents.is_empty());
                assert_eq!(detail.signals.len(), 2);
                assert!(
                    detail
                        .signals
                        .iter()
                        .any(|signal| signal.agent_id == worker_id),
                    "worker leave signal should remain visible in async detail"
                );
            });
        });
    });
}

#[test]
fn start_session_direct_async_creates_in_sqlite() {
    with_temp_project(|project| {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let db_path = project
                .parent()
                .expect("project parent")
                .join("daemon.sqlite");
            let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                .await
                .expect("open async daemon db");

            let session_id = "00000000-0000-4000-8000-000000000501";
            let state = start_session_direct_async(
                &crate::daemon::protocol::SessionStartRequest {
                    title: "async direct start session".into(),
                    context: "async direct start".into(),
                    session_id: Some(session_id.into()),
                    project_dir: project.to_string_lossy().into(),
                    policy_preset: None,
                    base_ref: None,
                },
                &async_db,
            )
            .await
            .expect("start session via async db");

            assert_eq!(state.context, "async direct start");
            assert_eq!(state.status, SessionStatus::AwaitingLeader);
            assert!(state.leader_id.is_none());
            assert!(state.agents.is_empty());
            assert_eq!(state.metrics.agent_count, 0);

            let resolved = async_db
                .resolve_session(session_id)
                .await
                .expect("resolve")
                .expect("present");
            assert_eq!(resolved.state.context, "async direct start");
            assert_eq!(resolved.state.status, SessionStatus::AwaitingLeader);
            assert!(resolved.state.leader_id.is_none());
            assert!(resolved.state.agents.is_empty());
            assert_eq!(
                resolved.project.project_dir.as_deref(),
                Some(project.canonicalize().expect("canonical project").as_path())
            );
        });
    });
}

#[test]
fn join_session_direct_async_adds_agent() {
    with_temp_project(|project| {
        temp_env::with_var("CODEX_SESSION_ID", Some("async-join-worker"), || {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let db_path = project
                    .parent()
                    .expect("project parent")
                    .join("daemon.sqlite");
                let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                    .await
                    .expect("open async daemon db");

                let session_id = "00000000-0000-4000-8000-000000000502";
                start_session_direct_async(
                    &crate::daemon::protocol::SessionStartRequest {
                        title: "async join test session".into(),
                        context: "async join test".into(),
                        session_id: Some(session_id.into()),
                        project_dir: project.to_string_lossy().into(),
                        policy_preset: None,
                        base_ref: None,
                    },
                    &async_db,
                )
                .await
                .expect("start session");

                let joined = join_session_direct_async(
                    session_id,
                    &crate::daemon::protocol::SessionJoinRequest {
                        runtime: "codex".into(),
                        role: SessionRole::Worker,
                        fallback_role: None,
                        capabilities: vec![],
                        name: None,
                        project_dir: project.to_string_lossy().into(),
                        persona: None,
                    },
                    &async_db,
                )
                .await
                .expect("join session via async db");

                assert_eq!(joined.status, SessionStatus::AwaitingLeader);
                assert!(joined.leader_id.is_none());
                assert_eq!(joined.agents.len(), 1);

                let resolved = async_db
                    .resolve_session(session_id)
                    .await
                    .expect("resolve")
                    .expect("present");
                assert_eq!(resolved.state.status, SessionStatus::AwaitingLeader);
                assert!(resolved.state.leader_id.is_none());
                assert_eq!(resolved.state.agents.len(), 1);
            });
        });
    });
}
