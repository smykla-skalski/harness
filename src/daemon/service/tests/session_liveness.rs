use std::collections::BTreeSet;

use super::*;

#[test]
fn list_sessions_reads_cached_liveness_state_within_ttl() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon cached liveness summaries",
            "daemon-cached-liveness-summaries",
        );
        let db = setup_db_with_session(project, &fixture.state.session_id);
        clear_session_liveness_refresh_cache_entry(&fixture.state.session_id);

        let first_summary = list_sessions(true, Some(&db))
            .expect("first session summaries")
            .into_iter()
            .find(|summary| summary.session_id == fixture.state.session_id)
            .expect("first summary");
        assert_eq!(first_summary.leader_id, fixture.state.leader_id);
        assert_eq!(first_summary.metrics.agent_count, 2);
        assert_eq!(first_summary.metrics.active_agent_count, 2);

        set_log_mtime_seconds_ago(&fixture.leader_log, 600);

        let second_summary = list_sessions(true, Some(&db))
            .expect("second session summaries")
            .into_iter()
            .find(|summary| summary.session_id == fixture.state.session_id)
            .expect("second summary");
        assert_eq!(
            second_summary.leader_id, fixture.state.leader_id,
            "cached liveness should defer leader cleanup within the TTL"
        );
        assert_eq!(second_summary.metrics.agent_count, 2);
        assert_eq!(second_summary.metrics.active_agent_count, 2);
    });
}

#[test]
fn list_sessions_skips_liveness_disk_probe_when_db_session_has_no_live_agents() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon dead-session summaries",
            "daemon-dead-session-summaries",
        );
        set_log_mtime_seconds_ago(&fixture.leader_log, 600);
        set_log_mtime_seconds_ago(&fixture.worker_log, 600);

        let liveness = session_service::sync_agent_liveness(&fixture.state.session_id, project)
            .expect("sync dead liveness");
        assert_eq!(liveness.disconnected.len(), 2);

        let db = setup_db_with_session(project, &fixture.state.session_id);
        clear_session_liveness_refresh_cache_entry(&fixture.state.session_id);

        let state_path = crate::workspace::project_context_dir(project)
            .join("orchestration")
            .join("sessions")
            .join(&fixture.state.session_id)
            .join("state.json");
        fs::write(&state_path, "{not-valid-json").expect("corrupt state");

        let summary = list_sessions(true, Some(&db))
            .expect("session summaries should stay on the db fast path")
            .into_iter()
            .find(|summary| summary.session_id == fixture.state.session_id)
            .expect("summary");
        assert!(summary.leader_id.is_none());
        assert_eq!(summary.metrics.agent_count, 0);
        assert_eq!(summary.metrics.active_agent_count, 0);
    });
}

#[test]
fn list_sessions_reconciles_orphaned_active_session_without_state_file() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon orphaned liveness summaries",
            "daemon-orphaned-liveness-summaries",
        );
        let stale = (chrono::Utc::now() - chrono::Duration::seconds(600)).to_rfc3339();
        let mut stale_state = fixture.state.clone();
        stale.clone_into(&mut stale_state.updated_at);
        stale_state.last_activity_at = Some(stale.clone());
        for agent in stale_state.agents.values_mut() {
            agent.joined_at = stale.clone();
            stale.clone_into(&mut agent.updated_at);
            agent.last_activity_at = Some(stale.clone());
        }

        let db = setup_db_with_project(project);
        let project_id = index::discovered_project_for_checkout(project).project_id;
        db.sync_session(&project_id, &stale_state).expect("sync");
        clear_session_liveness_refresh_cache_entry(&stale_state.session_id);

        let state_dir = crate::workspace::project_context_dir(project)
            .join("orchestration")
            .join("sessions")
            .join(&stale_state.session_id);
        fs::remove_dir_all(&state_dir).expect("remove state dir");
        fs::remove_file(&fixture.leader_log).expect("remove leader log");
        fs::remove_file(&fixture.worker_log).expect("remove worker log");

        let summary = list_sessions(true, Some(&db))
            .expect("session summaries")
            .into_iter()
            .find(|summary| summary.session_id == stale_state.session_id)
            .expect("summary");
        assert_eq!(summary.status, SessionStatus::LeaderlessDegraded);
        assert!(summary.leader_id.is_none());
        assert_eq!(summary.metrics.agent_count, 0);
        assert_eq!(summary.metrics.active_agent_count, 0);

        let persisted = db
            .load_session_state(&stale_state.session_id)
            .expect("load state")
            .expect("session present");
        assert_eq!(persisted.status, SessionStatus::LeaderlessDegraded);
        assert!(persisted.leader_id.is_none());
        assert!(
            persisted
                .agents
                .values()
                .all(|agent| agent.status == AgentStatus::Disconnected)
        );
    });
}

#[test]
fn session_detail_async_reconciles_orphaned_active_session_without_state_file() {
    with_temp_project(|project| {
        let fixture = setup_session_with_worker_logs(
            project,
            "daemon async orphaned liveness detail",
            "daemon-async-orphaned-liveness-detail",
        );
        let stale = (chrono::Utc::now() - chrono::Duration::seconds(600)).to_rfc3339();
        let mut stale_state = fixture.state.clone();
        stale.clone_into(&mut stale_state.updated_at);
        stale_state.last_activity_at = Some(stale.clone());
        for agent in stale_state.agents.values_mut() {
            agent.joined_at = stale.clone();
            stale.clone_into(&mut agent.updated_at);
            agent.last_activity_at = Some(stale.clone());
        }

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let async_db = setup_async_db_with_session(project, &fixture.state.session_id).await;
            let project_id = index::discovered_project_for_checkout(project).project_id;
            async_db
                .save_session_state(&project_id, &stale_state)
                .await
                .expect("save stale state");
            clear_session_liveness_refresh_cache_entry(&stale_state.session_id);

            let state_dir = crate::workspace::project_context_dir(project)
                .join("orchestration")
                .join("sessions")
                .join(&stale_state.session_id);
            fs::remove_dir_all(&state_dir).expect("remove state dir");
            fs::remove_file(&fixture.leader_log).expect("remove leader log");
            fs::remove_file(&fixture.worker_log).expect("remove worker log");

            let detail = session_detail_async(&stale_state.session_id, Some(async_db.as_ref()))
                .await
                .expect("session detail");
            assert_eq!(detail.session.status, SessionStatus::LeaderlessDegraded);
            assert!(detail.session.leader_id.is_none());
            assert_eq!(detail.session.metrics.agent_count, 0);
            assert_eq!(detail.session.metrics.active_agent_count, 0);
            assert!(detail.agents.is_empty());

            let resolved = async_db
                .resolve_session(&stale_state.session_id)
                .await
                .expect("resolve session")
                .expect("session present");
            assert_eq!(resolved.state.status, SessionStatus::LeaderlessDegraded);
            assert!(resolved.state.leader_id.is_none());
            assert!(
                resolved
                    .state
                    .agents
                    .values()
                    .all(|agent| agent.status == AgentStatus::Disconnected)
            );
        });
    });
}

#[test]
fn list_sessions_keeps_recent_db_only_session_live_without_state_file() {
    with_temp_project(|project| {
        let (db, state) = setup_db_only_session(project);
        clear_session_liveness_refresh_cache_entry(&state.session_id);

        let summary = list_sessions(true, Some(&db))
            .expect("session summaries")
            .into_iter()
            .find(|summary| summary.session_id == state.session_id)
            .expect("summary");
        assert_eq!(summary.status, SessionStatus::Active);
        assert_eq!(summary.leader_id.as_deref(), state.leader_id.as_deref());
        assert_eq!(summary.metrics.agent_count, 1);
        assert_eq!(summary.metrics.active_agent_count, 1);
    });
}

#[test]
fn stale_session_ids_for_liveness_refresh_skips_recent_sessions() {
    let now = Instant::now();
    let mut cache = BTreeMap::new();

    let first = stale_session_ids_for_liveness_refresh(
        &mut cache,
        BTreeSet::from([String::from("sess-1")]),
        now,
    );
    assert_eq!(first, vec![String::from("sess-1")]);

    let second = stale_session_ids_for_liveness_refresh(
        &mut cache,
        BTreeSet::from([String::from("sess-1")]),
        now + Duration::from_secs(1),
    );
    assert!(second.is_empty(), "recent sessions should be skipped");

    let third = stale_session_ids_for_liveness_refresh(
        &mut cache,
        BTreeSet::from([String::from("sess-1")]),
        now + SESSION_LIVENESS_REFRESH_TTL + Duration::from_secs(1),
    );
    assert_eq!(third, vec![String::from("sess-1")]);
}
