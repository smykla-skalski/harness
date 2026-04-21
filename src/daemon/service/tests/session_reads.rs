use super::*;

fn set_adoption_metadata(project: &Path, session_id: &str) {
    let layout =
        crate::session::storage::layout_from_project_dir(project, session_id).expect("layout");
    crate::session::storage::update_state(&layout, |state| {
        state.external_origin = Some("/external/session-root".into());
        state.adopted_at = Some("2026-04-20T02:03:04Z".into());
        Ok(())
    })
    .expect("update adoption metadata");
}

#[test]
fn session_detail_promotes_live_worker_and_hides_dead_leader() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon leaderless detail",
            "daemon-leaderless-detail",
        );
        set_log_mtime_seconds_ago(&fixture.leader_log, 1_200);
        age_leader_state_activity(project, &fixture.state.session_id, 1_200);

        let db = setup_db_with_project(project);
        let project_id = index::discovered_project_for_checkout(project).project_id;
        db.sync_session(&project_id, &fixture.state).expect("sync");
        let detail = session_detail(&fixture.state.session_id, Some(&db)).expect("session detail");
        let promoted_leader_id = detail
            .session
            .leader_id
            .as_deref()
            .expect("promoted leader");
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
        set_log_mtime_seconds_ago(&fixture.leader_log, 1_200);
        age_leader_state_activity(project, &fixture.state.session_id, 1_200);

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
        set_log_mtime_seconds_ago(&fixture.leader_log, 1_200);
        age_leader_state_activity(project, &fixture.state.session_id, 1_200);

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
fn db_session_reads_preserve_adoption_metadata() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon adopted metadata db",
            "daemon-adopted-metadata-db",
        );
        set_adoption_metadata(project, &fixture.state.session_id);

        let db = setup_db_with_session(project, &fixture.state.session_id);
        let summary = list_sessions(true, Some(&db))
            .expect("session summaries")
            .into_iter()
            .find(|summary| summary.session_id == fixture.state.session_id)
            .expect("summary");
        let detail = session_detail(&fixture.state.session_id, Some(&db)).expect("session detail");

        assert_eq!(
            summary.external_origin.as_deref(),
            Some("/external/session-root")
        );
        assert_eq!(summary.adopted_at.as_deref(), Some("2026-04-20T02:03:04Z"));
        assert_eq!(
            detail.session.external_origin.as_deref(),
            Some("/external/session-root")
        );
        assert_eq!(
            detail.session.adopted_at.as_deref(),
            Some("2026-04-20T02:03:04Z")
        );
    });
}

#[test]
fn async_session_reads_preserve_adoption_metadata() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon adopted metadata async",
            "daemon-adopted-metadata-async",
        );
        set_adoption_metadata(project, &fixture.state.session_id);

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let async_db = setup_async_db_with_session(project, &fixture.state.session_id).await;
            clear_session_liveness_refresh_cache_entry(&fixture.state.session_id);

            let summary = list_sessions_async(true, Some(async_db.as_ref()))
                .await
                .expect("session summaries")
                .into_iter()
                .find(|summary| summary.session_id == fixture.state.session_id)
                .expect("summary");
            let detail = session_detail_async(&fixture.state.session_id, Some(async_db.as_ref()))
                .await
                .expect("session detail");

            assert_eq!(
                summary.external_origin.as_deref(),
                Some("/external/session-root")
            );
            assert_eq!(summary.adopted_at.as_deref(), Some("2026-04-20T02:03:04Z"));
            assert_eq!(
                detail.session.external_origin.as_deref(),
                Some("/external/session-root")
            );
            assert_eq!(
                detail.session.adopted_at.as_deref(),
                Some("2026-04-20T02:03:04Z")
            );
        });
    });
}

#[test]
fn resolve_runtime_session_agent_async_returns_match_for_live_worker() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon async runtime session resolve",
            "daemon-async-runtime-session-resolve",
        );
        let orchestration_session_id = fixture.state.session_id.clone();
        let status = session_service::session_status(&orchestration_session_id, project)
            .expect("session status");
        let worker = status
            .agents
            .values()
            .find(|agent| agent.runtime == "codex")
            .expect("worker agent");
        let worker_runtime_session = worker
            .agent_session_id
            .clone()
            .expect("worker runtime session id");
        let worker_agent_id = worker.agent_id.clone();

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let async_db = setup_async_db_with_session(project, &orchestration_session_id).await;

            let resolved = resolve_runtime_session_agent_async(
                "codex",
                &worker_runtime_session,
                Some(async_db.as_ref()),
            )
            .await
            .expect("resolve runtime session")
            .expect("live worker should resolve");

            assert_eq!(resolved.orchestration_session_id, orchestration_session_id);
            assert_eq!(resolved.agent_id, worker_agent_id);

            let missing = resolve_runtime_session_agent_async(
                "codex",
                "does-not-exist",
                Some(async_db.as_ref()),
            )
            .await
            .expect("resolve missing runtime session");
            assert!(
                missing.is_none(),
                "unknown runtime session must return None"
            );

            let wrong_runtime = resolve_runtime_session_agent_async(
                "claude",
                &worker_runtime_session,
                Some(async_db.as_ref()),
            )
            .await
            .expect("resolve cross-runtime");
            assert!(
                wrong_runtime.is_none(),
                "runtime mismatch must not leak codex agent to claude lookup"
            );
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
        set_log_mtime_seconds_ago(&fixture.leader_log, 1_200);
        age_leader_state_activity(project, &fixture.state.session_id, 1_200);

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let async_db = setup_async_db_with_session(project, &fixture.state.session_id).await;
            let detail = session_detail_async(&fixture.state.session_id, Some(async_db.as_ref()))
                .await
                .expect("session detail");
            let promoted_leader_id = detail
                .session
                .leader_id
                .as_deref()
                .expect("promoted leader");
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
