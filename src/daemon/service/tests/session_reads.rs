use super::*;

#[test]
fn sessions_updated_event_includes_projects_and_sessions() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon stream index payload",
            "",
            project,
            Some("claude"),
            Some("daemon-stream-index"),
        )
        .expect("start session");

        let event = sessions_updated_event(None).expect("sessions updated event");
        let payload: SessionsUpdatedPayload =
            serde_json::from_value(event.payload).expect("deserialize payload");

        assert_eq!(event.event, "sessions_updated");
        assert!(event.session_id.is_none());
        assert_eq!(payload.projects.len(), 1);
        assert_eq!(payload.sessions.len(), 1);
        assert_eq!(payload.sessions[0].session_id, state.session_id);
    });
}

#[test]
fn session_detail_marks_dead_leader_leaderless_and_hides_dead_agents() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon leaderless detail",
            "",
            project,
            Some("claude"),
            Some("daemon-leaderless-detail"),
        )
        .expect("start session");

        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("leaderless-worker-session"),
            || {
                session_service::join_session(
                    &state.session_id,
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join worker");
            },
        );

        let status = session_service::session_status(&state.session_id, project).expect("status");
        let leader = status
            .leader_id
            .as_ref()
            .and_then(|agent_id| status.agents.get(agent_id))
            .expect("leader agent");
        let worker = status
            .agents
            .values()
            .find(|agent| agent.runtime == "codex")
            .expect("worker agent");

        let leader_log = write_agent_log_file(
            project,
            "claude",
            leader
                .agent_session_id
                .as_deref()
                .expect("leader session id"),
        );
        set_log_mtime_seconds_ago(&leader_log, 600);
        write_agent_log_file(
            project,
            "codex",
            worker
                .agent_session_id
                .as_deref()
                .expect("worker session id"),
        );

        let db = setup_db_with_project(project);
        let project_id = index::discovered_project_for_checkout(project).project_id;
        db.sync_session(&project_id, &state).expect("sync");
        let detail = session_detail(&state.session_id, Some(&db)).expect("session detail");
        assert!(
            detail.session.leader_id.is_none(),
            "dead leader should clear leader_id"
        );
        assert_eq!(detail.session.metrics.agent_count, 1);
        assert_eq!(detail.session.metrics.active_agent_count, 1);
        assert_eq!(
            detail.agents.len(),
            1,
            "only the live worker should remain visible"
        );
        assert_eq!(detail.agents[0].runtime, "codex");
    });
}

#[test]
fn list_sessions_db_marks_dead_leader_leaderless_and_excludes_dead_members() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon leaderless summaries",
            "",
            project,
            Some("claude"),
            Some("daemon-leaderless-summaries"),
        )
        .expect("start session");

        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("leaderless-db-worker-session"),
            || {
                session_service::join_session(
                    &state.session_id,
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join worker");
            },
        );

        let status = session_service::session_status(&state.session_id, project).expect("status");
        let leader = status
            .leader_id
            .as_ref()
            .and_then(|agent_id| status.agents.get(agent_id))
            .expect("leader agent");
        let worker = status
            .agents
            .values()
            .find(|agent| agent.runtime == "codex")
            .expect("worker agent");

        let leader_log = write_agent_log_file(
            project,
            "claude",
            leader
                .agent_session_id
                .as_deref()
                .expect("leader session id"),
        );
        set_log_mtime_seconds_ago(&leader_log, 600);
        write_agent_log_file(
            project,
            "codex",
            worker
                .agent_session_id
                .as_deref()
                .expect("worker session id"),
        );

        let db = setup_db_with_session(project, &state.session_id);

        let sessions = list_sessions(true, Some(&db)).expect("session summaries");
        let summary = sessions
            .into_iter()
            .find(|summary| summary.session_id == state.session_id)
            .expect("summary");
        assert!(
            summary.leader_id.is_none(),
            "dead leader should clear leader_id"
        );
        assert_eq!(summary.metrics.agent_count, 1);
        assert_eq!(summary.metrics.active_agent_count, 1);

        let synced_state = db
            .load_session_state(&state.session_id)
            .expect("load state")
            .expect("session present");
        assert!(
            synced_state.leader_id.is_none(),
            "db state should persist leaderless session"
        );
        let leader_id = state.leader_id.as_ref().expect("leader id");
        let dead_leader = synced_state.agents.get(leader_id).expect("leader agent");
        assert_eq!(dead_leader.status, AgentStatus::Disconnected);
    });
}

#[test]
fn list_sessions_async_marks_dead_leader_leaderless_and_excludes_dead_members() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon async leaderless summaries",
            "",
            project,
            Some("claude"),
            Some("daemon-async-leaderless-summaries"),
        )
        .expect("start session");

        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("leaderless-async-db-worker-session"),
            || {
                session_service::join_session(
                    &state.session_id,
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join worker");
            },
        );

        let status = session_service::session_status(&state.session_id, project).expect("status");
        let leader = status
            .leader_id
            .as_ref()
            .and_then(|agent_id| status.agents.get(agent_id))
            .expect("leader agent");
        let worker = status
            .agents
            .values()
            .find(|agent| agent.runtime == "codex")
            .expect("worker agent");

        let leader_log = write_agent_log_file(
            project,
            "claude",
            leader
                .agent_session_id
                .as_deref()
                .expect("leader session id"),
        );
        set_log_mtime_seconds_ago(&leader_log, 600);
        write_agent_log_file(
            project,
            "codex",
            worker
                .agent_session_id
                .as_deref()
                .expect("worker session id"),
        );

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let async_db = setup_async_db_with_session(project, &state.session_id).await;
            clear_session_liveness_refresh_cache_entry(&state.session_id);

            let sessions = list_sessions_async(true, Some(async_db.as_ref()))
                .await
                .expect("session summaries");
            let summary = sessions
                .into_iter()
                .find(|summary| summary.session_id == state.session_id)
                .expect("summary");
            assert!(
                summary.leader_id.is_none(),
                "dead leader should clear leader_id"
            );
            assert_eq!(summary.metrics.agent_count, 1);
            assert_eq!(summary.metrics.active_agent_count, 1);

            let resolved = async_db
                .resolve_session(&state.session_id)
                .await
                .expect("resolve session")
                .expect("session present");
            assert!(
                resolved.state.leader_id.is_none(),
                "db state should persist leaderless session"
            );
            let leader_id = state.leader_id.as_ref().expect("leader id");
            let dead_leader = resolved.state.agents.get(leader_id).expect("leader agent");
            assert_eq!(dead_leader.status, AgentStatus::Disconnected);
        });
    });
}

#[test]
fn list_sessions_reads_cached_liveness_state_within_ttl() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon cached liveness summaries",
            "",
            project,
            Some("claude"),
            Some("daemon-cached-liveness-summaries"),
        )
        .expect("start session");

        temp_env::with_var("CODEX_SESSION_ID", Some("cached-db-worker-session"), || {
            session_service::join_session(
                &state.session_id,
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker");
        });

        let status = session_service::session_status(&state.session_id, project).expect("status");
        let leader = status
            .leader_id
            .as_ref()
            .and_then(|agent_id| status.agents.get(agent_id))
            .expect("leader agent");
        let worker = status
            .agents
            .values()
            .find(|agent| agent.runtime == "codex")
            .expect("worker agent");

        let leader_log = write_agent_log_file(
            project,
            "claude",
            leader
                .agent_session_id
                .as_deref()
                .expect("leader session id"),
        );
        write_agent_log_file(
            project,
            "codex",
            worker
                .agent_session_id
                .as_deref()
                .expect("worker session id"),
        );

        let db = setup_db_with_session(project, &state.session_id);
        clear_session_liveness_refresh_cache_entry(&state.session_id);

        let first_summary = list_sessions(true, Some(&db))
            .expect("first session summaries")
            .into_iter()
            .find(|summary| summary.session_id == state.session_id)
            .expect("first summary");
        assert_eq!(first_summary.leader_id, state.leader_id);
        assert_eq!(first_summary.metrics.agent_count, 2);
        assert_eq!(first_summary.metrics.active_agent_count, 2);

        set_log_mtime_seconds_ago(&leader_log, 600);

        let second_summary = list_sessions(true, Some(&db))
            .expect("second session summaries")
            .into_iter()
            .find(|summary| summary.session_id == state.session_id)
            .expect("second summary");
        assert_eq!(
            second_summary.leader_id, state.leader_id,
            "cached liveness should defer leader cleanup within the TTL"
        );
        assert_eq!(second_summary.metrics.agent_count, 2);
        assert_eq!(second_summary.metrics.active_agent_count, 2);
    });
}

#[test]
fn session_detail_async_marks_dead_leader_leaderless_and_hides_dead_agents() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon async leaderless detail",
            "",
            project,
            Some("claude"),
            Some("daemon-async-leaderless-detail"),
        )
        .expect("start session");

        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("leaderless-async-detail-worker-session"),
            || {
                session_service::join_session(
                    &state.session_id,
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join worker");
            },
        );

        let status = session_service::session_status(&state.session_id, project).expect("status");
        let leader = status
            .leader_id
            .as_ref()
            .and_then(|agent_id| status.agents.get(agent_id))
            .expect("leader agent");
        let worker = status
            .agents
            .values()
            .find(|agent| agent.runtime == "codex")
            .expect("worker agent");

        let leader_log = write_agent_log_file(
            project,
            "claude",
            leader
                .agent_session_id
                .as_deref()
                .expect("leader session id"),
        );
        set_log_mtime_seconds_ago(&leader_log, 600);
        write_agent_log_file(
            project,
            "codex",
            worker
                .agent_session_id
                .as_deref()
                .expect("worker session id"),
        );

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let async_db = setup_async_db_with_session(project, &state.session_id).await;
            let detail = session_detail_async(&state.session_id, Some(async_db.as_ref()))
                .await
                .expect("session detail");
            assert!(
                detail.session.leader_id.is_none(),
                "dead leader should clear leader_id"
            );
            assert_eq!(detail.session.metrics.agent_count, 1);
            assert_eq!(detail.session.metrics.active_agent_count, 1);
            assert_eq!(
                detail.agents.len(),
                1,
                "only the live worker should remain visible"
            );
            assert_eq!(detail.agents[0].runtime, "codex");
        });
    });
}

#[test]
fn list_sessions_skips_liveness_disk_probe_when_db_session_has_no_live_agents() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon dead-session summaries",
            "",
            project,
            Some("claude"),
            Some("daemon-dead-session-summaries"),
        )
        .expect("start session");

        temp_env::with_var("CODEX_SESSION_ID", Some("dead-db-worker-session"), || {
            session_service::join_session(
                &state.session_id,
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker");
        });

        let status = session_service::session_status(&state.session_id, project).expect("status");
        let leader = status
            .leader_id
            .as_ref()
            .and_then(|agent_id| status.agents.get(agent_id))
            .expect("leader agent");
        let worker = status
            .agents
            .values()
            .find(|agent| agent.runtime == "codex")
            .expect("worker agent");

        let leader_log = write_agent_log_file(
            project,
            "claude",
            leader
                .agent_session_id
                .as_deref()
                .expect("leader session id"),
        );
        let worker_log = write_agent_log_file(
            project,
            "codex",
            worker
                .agent_session_id
                .as_deref()
                .expect("worker session id"),
        );
        set_log_mtime_seconds_ago(&leader_log, 600);
        set_log_mtime_seconds_ago(&worker_log, 600);

        let liveness = session_service::sync_agent_liveness(&state.session_id, project)
            .expect("sync dead liveness");
        assert_eq!(liveness.disconnected.len(), 2);

        let db = setup_db_with_session(project, &state.session_id);
        clear_session_liveness_refresh_cache_entry(&state.session_id);

        let state_path = crate::workspace::project_context_dir(project)
            .join("orchestration")
            .join("sessions")
            .join(&state.session_id)
            .join("state.json");
        fs::write(&state_path, "{not-valid-json").expect("corrupt state");

        let summary = list_sessions(true, Some(&db))
            .expect("session summaries should stay on the db fast path")
            .into_iter()
            .find(|summary| summary.session_id == state.session_id)
            .expect("summary");
        assert!(summary.leader_id.is_none());
        assert_eq!(summary.metrics.agent_count, 0);
        assert_eq!(summary.metrics.active_agent_count, 0);
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

#[test]
fn global_stream_initial_events_include_current_session_index() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon stream initial index payload",
            "",
            project,
            Some("claude"),
            Some("daemon-stream-initial-index"),
        )
        .expect("start session");

        let events = global_stream_initial_events(None);
        let snapshot = events
            .iter()
            .find(|event| event.event == "sessions_updated")
            .expect("sessions_updated event");
        let payload: SessionsUpdatedPayload =
            serde_json::from_value(snapshot.payload.clone()).expect("deserialize payload");

        assert_eq!(events[0].event, "ready");
        assert!(events[0].session_id.is_none());
        assert!(
            payload
                .sessions
                .iter()
                .any(|session| { session.session_id == state.session_id })
        );
    });
}

#[test]
fn session_stream_initial_events_include_current_session_snapshot() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon stream initial session payload",
            "",
            project,
            Some("claude"),
            Some("daemon-stream-initial-session"),
        )
        .expect("start session");

        let events = session_stream_initial_events(&state.session_id, None);
        let update = events
            .iter()
            .find(|event| event.event == "session_updated")
            .expect("session_updated event");
        let payload: SessionUpdatedPayload =
            serde_json::from_value(update.payload.clone()).expect("deserialize payload");

        assert_eq!(events[0].event, "ready");
        assert_eq!(
            events[0].session_id.as_deref(),
            Some(state.session_id.as_str())
        );
        assert_eq!(
            update.session_id.as_deref(),
            Some(state.session_id.as_str())
        );
        assert_eq!(payload.detail.session.session_id, state.session_id);
        assert!(payload.extensions_pending);
    });
}

#[test]
fn session_updated_event_includes_detail_without_timeline() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon stream session payload",
            "",
            project,
            Some("claude"),
            Some("daemon-stream-session"),
        )
        .expect("start session");
        let leader_id = state.leader_id.expect("leader id");
        append_project_ledger_entry(project);
        session_service::create_task(
            &state.session_id,
            "materialize timeline",
            None,
            crate::session::types::TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("create task");

        let event = session_updated_event(&state.session_id, None).expect("session updated event");
        let payload: SessionUpdatedPayload =
            serde_json::from_value(event.payload).expect("deserialize payload");

        assert_eq!(event.event, "session_updated");
        assert_eq!(event.session_id.as_deref(), Some(state.session_id.as_str()));
        assert_eq!(payload.detail.session.session_id, state.session_id);
        assert!(payload.timeline.is_none());
    });
}
