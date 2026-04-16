use super::*;

#[test]
fn leave_session_db_direct_marks_leaderless_degraded_without_successor() {
    with_temp_project(|project| {
        let (db, state) = setup_db_only_session(project);
        let leader_id = state.leader_id.clone().expect("leader id");

        let detail = leave_session(
            &state.session_id,
            &SessionLeaveRequest {
                agent_id: leader_id.clone(),
            },
            Some(&db),
        )
        .expect("leave session via db");

        assert_eq!(detail.session.status, SessionStatus::LeaderlessDegraded);
        assert!(detail.session.leader_id.is_none());

        let db_state = db
            .load_session_state(&state.session_id)
            .expect("load state")
            .expect("state present");
        assert_eq!(db_state.status, SessionStatus::LeaderlessDegraded);
        assert!(db_state.leader_id.is_none());
        assert_eq!(db_state.agents[&leader_id].status, AgentStatus::Disconnected);
    });
}

#[test]
fn leave_session_async_direct_marks_leaderless_degraded_without_successor() {
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
            let state = start_session_direct_async(
                &crate::daemon::protocol::SessionStartRequest {
                    title: "async leave session".into(),
                    context: "async leave".into(),
                    runtime: "claude".into(),
                    session_id: Some("daemon-async-leave".into()),
                    project_dir: project.to_string_lossy().into(),
                    policy_preset: None,
                },
                &async_db,
            )
            .await
            .expect("start session");
            let leader_id = state.leader_id.clone().expect("leader id");

            let detail = leave_session_async(
                "daemon-async-leave",
                &SessionLeaveRequest {
                    agent_id: leader_id.clone(),
                },
                &async_db,
            )
            .await
            .expect("leave via async db");

            assert_eq!(detail.session.status, SessionStatus::LeaderlessDegraded);
            assert!(detail.session.leader_id.is_none());

            let resolved = async_db
                .resolve_session("daemon-async-leave")
                .await
                .expect("resolve session")
                .expect("state present");
            assert_eq!(resolved.state.status, SessionStatus::LeaderlessDegraded);
            assert!(resolved.state.leader_id.is_none());
            assert_eq!(
                resolved.state.agents[&leader_id].status,
                AgentStatus::Disconnected
            );
        });
    });
}
