use super::*;

#[test]
fn sync_liveness_keeps_interactive_agent_idle_after_ten_quiet_minutes() {
    with_temp_project(|project| {
        start_active_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("00000000-0000-4002-8000-000000000030"),
        )
        .expect("start");

        temp_env::with_var("CODEX_SESSION_ID", Some("interactive-worker"), || {
            join_session(
                "00000000-0000-4002-8000-000000000030",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker");
        });

        let state =
            session_status("00000000-0000-4002-8000-000000000030", project).expect("status");
        let worker_id = find_agent_by_runtime(&state, "codex").agent_id.clone();
        age_agent_activity(
            project,
            "00000000-0000-4002-8000-000000000030",
            &worker_id,
            600,
        );

        let log_path = write_agent_log_file(project, "codex", "interactive-worker");
        set_log_mtime_seconds_ago(&log_path, 600);
        write_agent_log_file(project, "claude", "test-service");

        let result =
            sync_agent_liveness("00000000-0000-4002-8000-000000000030", project).expect("sync");

        assert!(
            result.disconnected.is_empty(),
            "interactive workers should not disconnect after ten quiet minutes"
        );
        assert_eq!(result.idled, vec![worker_id.clone()]);

        let updated =
            session_status("00000000-0000-4002-8000-000000000030", project).expect("updated");
        assert_eq!(
            updated.agents.get(&worker_id).expect("worker").status,
            AgentStatus::Idle
        );
    });
}

#[test]
fn sync_liveness_prefers_recent_state_activity_over_stale_runtime_log() {
    with_temp_project(|project| {
        start_active_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("00000000-0000-4002-8000-000000000036"),
        )
        .expect("start");

        temp_env::with_var("CODEX_SESSION_ID", Some("state-activity-worker"), || {
            join_session(
                "00000000-0000-4002-8000-000000000036",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker");
        });

        let state =
            session_status("00000000-0000-4002-8000-000000000036", project).expect("status");
        let worker_id = find_agent_by_runtime(&state, "codex").agent_id.clone();

        let log_path = write_agent_log_file(project, "codex", "state-activity-worker");
        set_log_mtime_seconds_ago(&log_path, 1_200);
        write_agent_log_file(project, "claude", "test-service");

        let fresh = utc_now();
        let layout =
            storage::layout_from_project_dir(project, "00000000-0000-4002-8000-000000000036")
                .expect("layout");
        storage::update_state(&layout, |state| {
            let worker = state.agents.get_mut(&worker_id).expect("worker");
            worker.last_activity_at = Some(fresh.clone());
            worker.updated_at = fresh.clone();
            state.last_activity_at = Some(fresh.clone());
            Ok(())
        })
        .expect("refresh worker state activity");

        let result =
            sync_agent_liveness("00000000-0000-4002-8000-000000000036", project).expect("sync");

        assert!(
            result.disconnected.is_empty(),
            "fresh session activity should beat stale transcript mtimes"
        );
        assert!(result.idled.is_empty());

        let updated =
            session_status("00000000-0000-4002-8000-000000000036", project).expect("updated");
        assert_eq!(
            updated.agents.get(&worker_id).expect("worker").status,
            AgentStatus::Active
        );
    });
}

#[test]
fn sync_liveness_keeps_pending_signal_available_for_stale_agent() {
    with_temp_project(|project| {
        let state = start_active_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("00000000-0000-4002-8000-000000000034"),
        )
        .expect("start");
        let leader_id = state.leader_id.expect("leader");

        temp_env::with_var("CODEX_SESSION_ID", Some("pending-signal-worker"), || {
            join_session(
                "00000000-0000-4002-8000-000000000034",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker");
        });

        let state =
            session_status("00000000-0000-4002-8000-000000000034", project).expect("status");
        let worker = find_agent_by_runtime(&state, "codex");
        let worker_id = worker.agent_id.clone();
        let worker_session_id = worker.agent_session_id.clone().expect("worker session id");
        age_agent_activity(
            project,
            "00000000-0000-4002-8000-000000000034",
            &worker_id,
            1_200,
        );

        let log_path = write_agent_log_file(project, "codex", &worker_session_id);
        set_log_mtime_seconds_ago(&log_path, 1_200);
        write_agent_log_file(project, "claude", "test-service");

        send_signal(
            "00000000-0000-4002-8000-000000000034",
            &worker_id,
            "inject_context",
            "queued instructions",
            Some("pick up the queued work"),
            &leader_id,
            project,
        )
        .expect("send signal");

        let runtime = runtime::runtime_for_name("codex").expect("runtime");
        let signal_dir = runtime.signal_dir(project, &worker_session_id);
        assert_eq!(
            runtime::signal::read_pending_signals(&signal_dir)
                .expect("pending before sync")
                .len(),
            1
        );

        let result =
            sync_agent_liveness("00000000-0000-4002-8000-000000000034", project).expect("sync");

        assert!(
            result.disconnected.is_empty(),
            "pending signals must keep the target agent connected long enough for delivery"
        );
        assert_eq!(result.idled, vec![worker_id.clone()]);
        assert_eq!(
            runtime::signal::read_pending_signals(&signal_dir)
                .expect("pending after sync")
                .len(),
            1,
            "sync must not expire undelivered signals"
        );

        let updated =
            session_status("00000000-0000-4002-8000-000000000034", project).expect("updated");
        assert_eq!(
            updated.agents.get(&worker_id).expect("worker").status,
            AgentStatus::Idle
        );
    });
}

#[test]
fn sync_liveness_skips_disconnect_for_acp_managed_gemini_agents() {
    with_temp_project(|project| {
        start_active_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("00000000-0000-4002-8000-00000000002f"),
        )
        .expect("start");

        temp_env::with_var("GEMINI_SESSION_ID", Some("native-gemini-worker"), || {
            join_session(
                "00000000-0000-4002-8000-00000000002f",
                SessionRole::Worker,
                "gemini",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker");
        });

        let state =
            session_status("00000000-0000-4002-8000-00000000002f", project).expect("status");
        let worker_id = find_agent_by_runtime(&state, "gemini").agent_id.clone();
        let layout =
            storage::layout_from_project_dir(project, "00000000-0000-4002-8000-00000000002f")
                .expect("layout");
        storage::update_state(&layout, |state| {
            let worker = state.agents.get_mut(&worker_id).expect("worker");
            worker.managed_agent =
                Some(crate::session::types::ManagedAgentRef::acp("acp-gemini-1"));
            worker.agent_session_id = Some("acp-runtime-session-1".into());
            Ok(())
        })
        .expect("bind acp worker");
        age_agent_activity(
            project,
            "00000000-0000-4002-8000-00000000002f",
            &worker_id,
            1_200,
        );
        write_agent_log_file(project, "claude", "test-service");

        let result =
            sync_agent_liveness("00000000-0000-4002-8000-00000000002f", project).expect("sync");

        assert!(
            result.disconnected.is_empty(),
            "ACP-managed Gemini agents should stay connected when native runtime logs are unavailable"
        );
        assert!(result.idled.is_empty());

        let updated =
            session_status("00000000-0000-4002-8000-00000000002f", project).expect("updated");
        assert_eq!(
            updated.agents.get(&worker_id).expect("worker").status,
            AgentStatus::Active
        );
    });
}
