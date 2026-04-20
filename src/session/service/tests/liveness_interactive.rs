use super::*;

#[test]
fn sync_liveness_keeps_interactive_agent_idle_after_ten_quiet_minutes() {
    with_temp_project(|project| {
        start_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("sync-interactive-idle"),
        )
        .expect("start");

        temp_env::with_var("CODEX_SESSION_ID", Some("interactive-worker"), || {
            join_session(
                "sync-interactive-idle",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker");
        });

        let state = session_status("sync-interactive-idle", project).expect("status");
        let worker_id = find_agent_by_runtime(&state, "codex").agent_id.clone();
        age_agent_activity(project, "sync-interactive-idle", &worker_id, 600);

        let log_path = write_agent_log_file(project, "codex", "interactive-worker");
        set_log_mtime_seconds_ago(&log_path, 600);
        write_agent_log_file(project, "claude", "test-service");

        let result = sync_agent_liveness("sync-interactive-idle", project).expect("sync");

        assert!(
            result.disconnected.is_empty(),
            "interactive workers should not disconnect after ten quiet minutes"
        );
        assert_eq!(result.idled, vec![worker_id.clone()]);

        let updated = session_status("sync-interactive-idle", project).expect("updated");
        assert_eq!(
            updated.agents.get(&worker_id).expect("worker").status,
            AgentStatus::Idle
        );
    });
}

#[test]
fn sync_liveness_prefers_recent_state_activity_over_stale_runtime_log() {
    with_temp_project(|project| {
        start_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("sync-state-activity"),
        )
        .expect("start");

        temp_env::with_var("CODEX_SESSION_ID", Some("state-activity-worker"), || {
            join_session(
                "sync-state-activity",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker");
        });

        let state = session_status("sync-state-activity", project).expect("status");
        let worker_id = find_agent_by_runtime(&state, "codex").agent_id.clone();

        let log_path = write_agent_log_file(project, "codex", "state-activity-worker");
        set_log_mtime_seconds_ago(&log_path, 1_200);
        write_agent_log_file(project, "claude", "test-service");

        let fresh = utc_now();
        storage::update_state_legacy(project, "sync-state-activity", |state| {
            let worker = state.agents.get_mut(&worker_id).expect("worker");
            worker.last_activity_at = Some(fresh.clone());
            worker.updated_at = fresh.clone();
            state.last_activity_at = Some(fresh.clone());
            Ok(())
        })
        .expect("refresh worker state activity");

        let result = sync_agent_liveness("sync-state-activity", project).expect("sync");

        assert!(
            result.disconnected.is_empty(),
            "fresh session activity should beat stale transcript mtimes"
        );
        assert!(result.idled.is_empty());

        let updated = session_status("sync-state-activity", project).expect("updated");
        assert_eq!(
            updated.agents.get(&worker_id).expect("worker").status,
            AgentStatus::Active
        );
    });
}

#[test]
fn sync_liveness_keeps_pending_signal_available_for_stale_agent() {
    with_temp_project(|project| {
        let state = start_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("sync-pending-signal"),
        )
        .expect("start");
        let leader_id = state.leader_id.expect("leader");

        temp_env::with_var("CODEX_SESSION_ID", Some("pending-signal-worker"), || {
            join_session(
                "sync-pending-signal",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker");
        });

        let state = session_status("sync-pending-signal", project).expect("status");
        let worker = find_agent_by_runtime(&state, "codex");
        let worker_id = worker.agent_id.clone();
        let worker_session_id = worker.agent_session_id.clone().expect("worker session id");
        age_agent_activity(project, "sync-pending-signal", &worker_id, 1_200);

        let log_path = write_agent_log_file(project, "codex", &worker_session_id);
        set_log_mtime_seconds_ago(&log_path, 1_200);
        write_agent_log_file(project, "claude", "test-service");

        send_signal(
            "sync-pending-signal",
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

        let result = sync_agent_liveness("sync-pending-signal", project).expect("sync");

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

        let updated = session_status("sync-pending-signal", project).expect("updated");
        assert_eq!(
            updated.agents.get(&worker_id).expect("worker").status,
            AgentStatus::Idle
        );
    });
}
