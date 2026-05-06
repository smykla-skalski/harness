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

fn archive_session_state(project: &Path, session_id: &str) {
    let layout =
        crate::session::storage::layout_from_project_dir(project, session_id).expect("layout");
    crate::session::storage::update_state(&layout, |state| {
        state.archived_at = Some("2026-05-02T00:00:00Z".into());
        Ok(())
    })
    .expect("archive session state");
}

#[test]
fn session_detail_promotes_live_worker_and_hides_dead_leader() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon leaderless detail",
            "213d9b3b-955d-584d-9faa-c3cdd541c914",
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
            "476ccd0e-4dbc-57ce-8d7a-6f1f34b8069a",
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
        assert_eq!(dead_leader.status, AgentStatus::disconnected_unknown());
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
fn archived_sessions_are_hidden_from_sync_db_summary_detail_and_timeline_reads() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon archived sync reads",
            "d985d715-5ef0-50c0-b73b-00a48f5a66ed",
        );
        archive_session_state(project, &fixture.state.session_id);

        let db = setup_db_with_project(project);
        let project_id = index::discovered_project_for_checkout(project).project_id;
        let mut archived_state = fixture.state.clone();
        archived_state.archived_at = Some("2026-05-02T00:00:00Z".into());
        db.sync_session(&project_id, &archived_state).expect("sync");
        let request = TimelineWindowRequest {
            limit: Some(20),
            ..TimelineWindowRequest::default()
        };

        assert!(
            list_sessions(true, Some(&db))
                .expect("session summaries")
                .into_iter()
                .all(|summary| summary.session_id != fixture.state.session_id)
        );
        assert!(
            session_detail(&fixture.state.session_id, Some(&db)).is_err(),
            "archived sessions must be hidden from detail reads"
        );
        assert!(
            session_timeline_window(&fixture.state.session_id, &request, Some(&db)).is_err(),
            "archived sessions must be hidden from timeline reads"
        );
    });
}

#[test]
fn list_sessions_async_promotes_live_worker_and_excludes_dead_members() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon async leaderless summaries",
            "4be98c5f-701a-59aa-86d2-53ef6fa646c4",
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
            assert_eq!(dead_leader.status, AgentStatus::disconnected_unknown());
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
fn archived_sessions_are_hidden_from_async_db_summary_detail_and_timeline_reads() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon archived async reads",
            "11cf3459-8cf7-54fc-9663-92608a899d2f",
        );
        archive_session_state(project, &fixture.state.session_id);

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let async_db = Arc::new(
                crate::daemon::db::AsyncDaemonDb::connect(&project.join("daemon.sqlite"))
                    .await
                    .expect("open async daemon db"),
            );
            let resolved_project = index::discovered_project_for_checkout(project);
            async_db
                .sync_project(&resolved_project)
                .await
                .expect("sync project");
            let mut archived_state = fixture.state.clone();
            archived_state.archived_at = Some("2026-05-02T00:00:00Z".into());
            async_db
                .save_session_state(&resolved_project.project_id, &archived_state)
                .await
                .expect("save session state");
            clear_session_liveness_refresh_cache_entry(&fixture.state.session_id);
            let request = TimelineWindowRequest {
                limit: Some(20),
                ..TimelineWindowRequest::default()
            };

            assert!(
                list_sessions_async(true, Some(async_db.as_ref()))
                    .await
                    .expect("session summaries")
                    .into_iter()
                    .all(|summary| summary.session_id != fixture.state.session_id)
            );
            assert!(
                session_detail_async(&fixture.state.session_id, Some(async_db.as_ref()))
                    .await
                    .is_err(),
                "archived sessions must be hidden from async detail reads"
            );
            assert!(
                session_timeline_window_async(
                    &fixture.state.session_id,
                    &request,
                    Some(async_db.as_ref())
                )
                .await
                .is_err(),
                "archived sessions must be hidden from async timeline reads"
            );
        });
    });
}

#[test]
fn db_session_reads_preserve_adoption_metadata() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon adopted metadata db",
            "331b9776-49be-5c76-b6bf-7e17e3e65949",
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
            "cd396ce1-f2c7-562e-8b2f-e396794710f1",
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
            "9b5a80e8-79fe-580a-ab18-3b9abaca3cc0",
        );
        let orchestration_session_id = fixture.state.session_id;
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
            assert_eq!(resolved.session_agent_id, worker_agent_id);

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
            "1b36bd95-9a11-54a5-aa3a-1713016b6079",
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
