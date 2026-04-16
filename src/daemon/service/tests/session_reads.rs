use super::*;

#[test]
fn session_detail_promotes_live_worker_and_hides_dead_leader() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon leaderless detail",
            "daemon-leaderless-detail",
        );
        set_log_mtime_seconds_ago(&fixture.leader_log, 600);

        let db = setup_db_with_project(project);
        let project_id = index::discovered_project_for_checkout(project).project_id;
        db.sync_session(&project_id, &fixture.state).expect("sync");
        let detail = session_detail(&fixture.state.session_id, Some(&db)).expect("session detail");
        let promoted_leader_id = detail.session.leader_id.as_deref().expect("promoted leader");
        assert_eq!(detail.session.status, SessionStatus::Active);
        assert_eq!(detail.session.metrics.agent_count, 1);
        assert_eq!(detail.session.metrics.active_agent_count, 1);
        assert_eq!(
            detail.agents.len(),
            1,
            "only the live worker should remain visible"
        );
        assert_eq!(detail.agents[0].agent_id, promoted_leader_id);
        assert_eq!(detail.agents[0].runtime, "codex");
        assert_eq!(detail.agents[0].role, SessionRole::Leader);
    });
}

#[test]
fn list_sessions_db_promotes_live_worker_and_excludes_dead_members() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon leaderless summaries",
            "daemon-leaderless-summaries",
        );
        set_log_mtime_seconds_ago(&fixture.leader_log, 600);

        let db = setup_db_with_session(project, &fixture.state.session_id);

        let sessions = list_sessions(true, Some(&db)).expect("session summaries");
        let summary = sessions
            .into_iter()
            .find(|summary| summary.session_id == fixture.state.session_id)
            .expect("summary");
        let promoted_leader_id = summary.leader_id.as_deref().expect("promoted leader");
        assert_eq!(summary.status, SessionStatus::Active);
        assert_eq!(summary.metrics.agent_count, 1);
        assert_eq!(summary.metrics.active_agent_count, 1);

        let synced_state = db
            .load_session_state(&fixture.state.session_id)
            .expect("load state")
            .expect("session present");
        let leader_id = fixture.state.leader_id.as_ref().expect("leader id");
        assert_eq!(
            synced_state.leader_id.as_deref(),
            Some(promoted_leader_id),
            "db state should persist the promoted successor"
        );
        let dead_leader = synced_state.agents.get(leader_id).expect("leader agent");
        assert_eq!(dead_leader.status, AgentStatus::Disconnected);
        let promoted = synced_state
            .leader_id
            .as_deref()
            .and_then(|agent_id| synced_state.agents.get(agent_id))
            .expect("promoted agent");
        assert_eq!(promoted.runtime, "codex");
        assert_eq!(promoted.role, SessionRole::Leader);
    });
}

#[test]
fn list_sessions_async_promotes_live_worker_and_excludes_dead_members() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon async leaderless summaries",
            "daemon-async-leaderless-summaries",
        );
        set_log_mtime_seconds_ago(&fixture.leader_log, 600);

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let async_db = setup_async_db_with_session(project, &fixture.state.session_id).await;
            clear_session_liveness_refresh_cache_entry(&fixture.state.session_id);

            let sessions = list_sessions_async(true, Some(async_db.as_ref()))
                .await
                .expect("session summaries");
            let summary = sessions
                .into_iter()
                .find(|summary| summary.session_id == fixture.state.session_id)
                .expect("summary");
            let promoted_leader_id = summary.leader_id.as_deref().expect("promoted leader");
            assert_eq!(summary.status, SessionStatus::Active);
            assert_eq!(summary.metrics.agent_count, 1);
            assert_eq!(summary.metrics.active_agent_count, 1);

            let resolved = async_db
                .resolve_session(&fixture.state.session_id)
                .await
                .expect("resolve session")
                .expect("session present");
            let leader_id = fixture.state.leader_id.as_ref().expect("leader id");
            assert_eq!(
                resolved.state.leader_id.as_deref(),
                Some(promoted_leader_id),
                "db state should persist the promoted successor"
            );
            let dead_leader = resolved.state.agents.get(leader_id).expect("leader agent");
            assert_eq!(dead_leader.status, AgentStatus::Disconnected);
            let promoted = resolved
                .state
                .leader_id
                .as_deref()
                .and_then(|agent_id| resolved.state.agents.get(agent_id))
                .expect("promoted agent");
            assert_eq!(promoted.runtime, "codex");
            assert_eq!(promoted.role, SessionRole::Leader);
        });
    });
}

#[test]
fn session_detail_async_promotes_live_worker_and_hides_dead_leader() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon async leaderless detail",
            "daemon-async-leaderless-detail",
        );
        set_log_mtime_seconds_ago(&fixture.leader_log, 600);

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let async_db = setup_async_db_with_session(project, &fixture.state.session_id).await;
            let detail = session_detail_async(&fixture.state.session_id, Some(async_db.as_ref()))
                .await
                .expect("session detail");
            let promoted_leader_id = detail.session.leader_id.as_deref().expect("promoted leader");
            assert_eq!(detail.session.status, SessionStatus::Active);
            assert_eq!(detail.session.metrics.agent_count, 1);
            assert_eq!(detail.session.metrics.active_agent_count, 1);
            assert_eq!(
                detail.agents.len(),
                1,
                "only the live worker should remain visible"
            );
            assert_eq!(detail.agents[0].agent_id, promoted_leader_id);
            assert_eq!(detail.agents[0].runtime, "codex");
            assert_eq!(detail.agents[0].role, SessionRole::Leader);
        });
    });
}
