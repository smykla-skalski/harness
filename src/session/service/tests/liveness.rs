use super::*;

#[test]
fn sync_liveness_transitions_stale_agent_to_disconnected() {
    with_temp_project(|project| {
        let state =
            start_session("test", "", project, Some("claude"), Some("sync-1")).expect("start");
        let leader_id = state.leader_id.clone().expect("leader");

        temp_env::with_var("CODEX_SESSION_ID", Some("worker-sess"), || {
            join_session(
                "sync-1",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker");
        });

        let state = session_status("sync-1", project).expect("status");
        let worker_id = find_agent_by_runtime(&state, "codex").agent_id.clone();

        // Write a log file for the worker with old mtime (600s > 300s threshold)
        let log_path = write_agent_log_file(project, "codex", "worker-sess");
        set_log_mtime_seconds_ago(&log_path, 600);

        // Write a fresh log for the leader
        write_agent_log_file(project, "claude", "test-service");

        let result = sync_agent_liveness("sync-1", project).expect("sync");

        assert_eq!(result.disconnected.len(), 1);
        assert!(result.disconnected.contains(&worker_id));

        let state = session_status("sync-1", project).expect("status");
        let worker = state.agents.get(&worker_id).expect("worker");
        assert_eq!(worker.status, AgentStatus::Disconnected);

        let leader = state.agents.get(&leader_id).expect("leader");
        assert_eq!(leader.status, AgentStatus::Active);

        assert_eq!(state.metrics.active_agent_count, 1);
    });
}

#[test]
fn sync_liveness_updates_last_activity_from_runtime() {
    with_temp_project(|project| {
        start_session("test", "", project, Some("claude"), Some("sync-2")).expect("start");

        // Write a fresh log for the leader
        let leader_log = crate::workspace::project_context_dir(project)
            .join("agents/sessions/claude/test-service/raw.jsonl");
        fs_err::create_dir_all(leader_log.parent().unwrap()).expect("dirs");
        fs_err::write(&leader_log, "{}\n").expect("write log");

        let _ = sync_agent_liveness("sync-2", project).expect("sync");

        let state = session_status("sync-2", project).expect("status");
        let leader = state.agents.values().next().expect("leader");
        // last_activity_at should be updated from the runtime log's mtime
        assert!(leader.last_activity_at.is_some());
    });
}

#[test]
fn sync_liveness_uses_orchestration_session_fallback_for_legacy_agents() {
    with_temp_project(|project| {
        start_session("test", "", project, Some("claude"), Some("sync-legacy")).expect("start");

        join_session(
            "sync-legacy",
            SessionRole::Worker,
            "codex",
            &[],
            None,
            project,
            None,
        )
        .expect("join worker");

        let state = session_status("sync-legacy", project).expect("status");
        let worker_id = find_agent_by_runtime(&state, "codex").agent_id.clone();
        storage::update_state(project, "sync-legacy", |state| {
            state
                .agents
                .get_mut(&worker_id)
                .expect("worker")
                .agent_session_id = None;
            Ok(())
        })
        .expect("clear worker runtime session id for legacy fixture");

        let state = session_status("sync-legacy", project).expect("status");
        let worker = state.agents.get(&worker_id).expect("worker");
        assert!(worker.agent_session_id.is_none());

        let legacy_worker_log = write_agent_log_file(project, "codex", "sync-legacy");
        set_log_mtime_seconds_ago(&legacy_worker_log, 600);
        write_agent_log_file(project, "claude", "test-service");

        let result = sync_agent_liveness("sync-legacy", project).expect("sync");

        assert_eq!(result.disconnected, vec![worker_id.clone()]);
        let updated = session_status("sync-legacy", project).expect("updated");
        assert_eq!(
            updated.agents.get(&worker_id).expect("worker").status,
            AgentStatus::Disconnected
        );
    });
}

#[test]
fn sync_liveness_clears_dead_leader_and_marks_session_leaderless() {
    with_temp_project(|project| {
        let _state = start_session("test", "", project, Some("claude"), Some("sync-leader"))
            .expect("start");

        temp_env::with_var("CODEX_SESSION_ID", Some("leaderless-worker"), || {
            join_session(
                "sync-leader",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker");
        });

        let state = session_status("sync-leader", project).expect("status");
        let leader_id = state.leader_id.clone().expect("leader");
        let leader = state.agents.get(&leader_id).expect("leader agent");
        let worker = find_agent_by_runtime(&state, "codex");

        let leader_log = write_agent_log_file(
            project,
            "claude",
            leader.agent_session_id.as_deref().expect("leader session"),
        );
        set_log_mtime_seconds_ago(&leader_log, 600);
        write_agent_log_file(
            project,
            "codex",
            worker.agent_session_id.as_deref().expect("worker session"),
        );

        let result = sync_agent_liveness("sync-leader", project).expect("sync");

        assert_eq!(result.disconnected, vec![leader_id.clone()]);

        let updated = session_status("sync-leader", project).expect("updated status");
        assert!(
            updated.leader_id.is_none(),
            "dead leader should clear leader_id"
        );
        assert_eq!(
            updated.agents.get(&leader_id).expect("leader agent").status,
            AgentStatus::Disconnected
        );
        assert_eq!(updated.metrics.agent_count, 1);
        assert_eq!(updated.metrics.active_agent_count, 1);
    });
}

#[test]
fn sync_liveness_returns_dead_agent_task_to_open() {
    with_temp_project(|project| {
        let state =
            start_session("test", "", project, Some("claude"), Some("sync-3")).expect("start");
        let leader_id = state.leader_id.clone().expect("leader");

        temp_env::with_var("CODEX_SESSION_ID", Some("worker-sess-3"), || {
            join_session(
                "sync-3",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join");
        });

        let state = session_status("sync-3", project).expect("status");
        let worker_id = find_agent_by_runtime(&state, "codex").agent_id.clone();

        // Create a task and assign it to the worker
        let task = create_task(
            "sync-3",
            "test task",
            Some("details"),
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("create task");
        assign_task("sync-3", &task.task_id, &worker_id, &leader_id, project).expect("assign");
        update_task(
            "sync-3",
            &task.task_id,
            TaskStatus::InProgress,
            None,
            &worker_id,
            project,
        )
        .expect("start");

        // Make the worker agent stale
        let log_path = write_agent_log_file(project, "codex", "worker-sess-3");
        set_log_mtime_seconds_ago(&log_path, 600);

        // Keep leader alive
        write_agent_log_file(project, "claude", "test-service");

        let _ = sync_agent_liveness("sync-3", project).expect("sync");

        let state = session_status("sync-3", project).expect("status");
        let task = state.tasks.get(&task.task_id).expect("task");
        assert_eq!(
            task.status,
            TaskStatus::Open,
            "dead agent task returns to Open"
        );
        assert!(task.assigned_to.is_none(), "dead agent task is unassigned");
    });
}

#[test]
fn sync_liveness_seven_agents_six_die() {
    with_temp_project(|project| {
        start_session("test", "", project, Some("claude"), Some("sync-4")).expect("start");

        // Join 6 more workers with distinct runtime session IDs
        for i in 1..=6 {
            let session_val = format!("worker-{i}");
            temp_env::with_var("CODEX_SESSION_ID", Some(&session_val), || {
                join_session(
                    "sync-4",
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join");
            });
        }

        // Make all 6 workers stale
        for i in 1..=6 {
            let log_path = write_agent_log_file(project, "codex", &format!("worker-{i}"));
            set_log_mtime_seconds_ago(&log_path, 600);
        }

        // Keep leader alive
        write_agent_log_file(project, "claude", "test-service");

        let result = sync_agent_liveness("sync-4", project).expect("sync");
        assert_eq!(result.disconnected.len(), 6);

        let state = session_status("sync-4", project).expect("status");
        assert_eq!(state.metrics.active_agent_count, 1);
        assert_eq!(state.metrics.agent_count, 1);
    });
}

#[test]
fn sync_liveness_skips_rewrite_when_state_is_unchanged() {
    with_temp_project(|project| {
        start_session("test", "", project, Some("claude"), Some("sync-noop")).expect("start");
        let leader_log = crate::workspace::project_context_dir(project)
            .join("agents/sessions/claude/test-service/raw.jsonl");
        fs_err::create_dir_all(leader_log.parent().unwrap()).expect("dirs");
        fs_err::write(&leader_log, "{}\n").expect("write log");

        let _ = sync_agent_liveness("sync-noop", project).expect("initial sync");
        let baseline = session_status("sync-noop", project).expect("baseline");

        let result = sync_agent_liveness("sync-noop", project).expect("noop sync");
        let after = session_status("sync-noop", project).expect("after");

        assert!(result.disconnected.is_empty());
        assert!(result.idled.is_empty());
        assert_eq!(after.state_version, baseline.state_version);
        assert_eq!(after.updated_at, baseline.updated_at);
    });
}

#[test]
fn leave_session_marks_agent_disconnected() {
    with_temp_project(|project| {
        let state =
            start_session("test", "", project, Some("claude"), Some("leave-1")).expect("start");
        let leader_id = state.leader_id.clone().expect("leader");

        temp_env::with_var("CODEX_SESSION_ID", Some("worker-leave"), || {
            join_session(
                "leave-1",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join");
        });

        let state = session_status("leave-1", project).expect("status");
        let worker_id = find_agent_by_runtime(&state, "codex").agent_id.clone();

        // Assign a task to the worker
        let task = create_task(
            "leave-1",
            "test task",
            Some("details"),
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("create task");
        assign_task("leave-1", &task.task_id, &worker_id, &leader_id, project).expect("assign");

        leave_session("leave-1", &worker_id, project).expect("leave");

        let state = session_status("leave-1", project).expect("status");
        let worker = state.agents.get(&worker_id).expect("worker");
        assert_eq!(worker.status, AgentStatus::Disconnected);

        let task = state.tasks.get(&task.task_id).expect("task");
        assert_eq!(task.status, TaskStatus::Open, "task returned to open");
        assert!(task.assigned_to.is_none(), "task unassigned");

        assert_eq!(state.metrics.active_agent_count, 1);
    });
}

#[test]
fn leave_session_leader_cannot_leave() {
    with_temp_project(|project| {
        let state =
            start_session("test", "", project, Some("claude"), Some("leave-2")).expect("start");
        let leader_id = state.leader_id.clone().expect("leader");

        let error =
            leave_session("leave-2", &leader_id, project).expect_err("leader cannot leave");
        assert_eq!(error.code(), "KSRCLI092");
    });
}
