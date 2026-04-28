use super::*;

#[test]
fn sync_liveness_transitions_stale_agent_to_disconnected() {
    with_temp_project(|project| {
        let state = start_active_session("test", "", project, Some("claude"), Some("sync-1"))
            .expect("start");
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
        age_agent_activity(project, "sync-1", &worker_id, 1_200);

        // Write a log file for the worker with old mtime beyond the interactive timeout.
        let log_path = write_agent_log_file(project, "codex", "worker-sess");
        set_log_mtime_seconds_ago(&log_path, 1_200);

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
        start_active_session("test", "", project, Some("claude"), Some("sync-2")).expect("start");

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
        start_active_session("test", "", project, Some("claude"), Some("sync-legacy"))
            .expect("start");

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
        let layout = storage::layout_from_project_dir(project, "sync-legacy").expect("layout");
        storage::update_state(&layout, |state| {
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
        age_agent_activity(project, "sync-legacy", &worker_id, 1_200);

        let legacy_worker_log = write_agent_log_file(project, "codex", "sync-legacy");
        set_log_mtime_seconds_ago(&legacy_worker_log, 1_200);
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
fn sync_liveness_marks_session_leaderless_degraded_when_dead_leader_has_no_successor() {
    with_temp_project(|project| {
        let state = start_active_session("test", "", project, Some("claude"), Some("sync-leader"))
            .expect("start");
        let leader_id = state.leader_id.clone().expect("leader");
        let leader = state.agents.get(&leader_id).expect("leader agent");
        age_agent_activity(project, "sync-leader", &leader_id, 1_200);

        let leader_log = write_agent_log_file(
            project,
            "claude",
            leader.agent_session_id.as_deref().expect("leader session"),
        );
        set_log_mtime_seconds_ago(&leader_log, 1_200);

        let result = sync_agent_liveness("sync-leader", project).expect("sync");

        assert_eq!(result.disconnected, vec![leader_id.clone()]);

        let updated = session_status("sync-leader", project).expect("updated status");
        assert_eq!(updated.status, SessionStatus::LeaderlessDegraded);
        assert!(
            updated.leader_id.is_none(),
            "dead leader should clear leader_id"
        );
        assert_eq!(
            updated.agents.get(&leader_id).expect("leader agent").status,
            AgentStatus::Disconnected
        );
        assert_eq!(updated.metrics.agent_count, 0);
        assert_eq!(updated.metrics.active_agent_count, 0);
    });
}

#[test]
fn sync_liveness_promotes_highest_priority_successor_within_same_role() {
    with_temp_project(|project| {
        let state = start_active_session_with_policy(
            "test",
            "",
            project,
            Some("claude"),
            Some("sync-promote-priority"),
            Some("swarm-default"),
        )
        .expect("start");
        let leader_id = state.leader_id.clone().expect("leader");
        let leader = state.agents.get(&leader_id).expect("leader agent");
        age_agent_activity(project, "sync-promote-priority", &leader_id, 1_200);

        temp_env::with_var("CODEX_SESSION_ID", Some("preferred-improver"), || {
            join_session(
                "sync-promote-priority",
                SessionRole::Improver,
                "codex",
                &["priority:90".into()],
                Some("preferred improver"),
                project,
                None,
            )
            .expect("join preferred improver");
        });
        temp_env::with_var("CODEX_SESSION_ID", Some("backup-improver"), || {
            join_session(
                "sync-promote-priority",
                SessionRole::Improver,
                "codex",
                &["priority:10".into()],
                Some("backup improver"),
                project,
                None,
            )
            .expect("join backup improver");
        });

        let current = session_status("sync-promote-priority", project).expect("status");
        let preferred_id = current
            .agents
            .values()
            .find(|agent| {
                agent
                    .capabilities
                    .iter()
                    .any(|capability| capability == "priority:90")
            })
            .expect("preferred improver")
            .agent_id
            .clone();

        let leader_log = write_agent_log_file(
            project,
            "claude",
            leader.agent_session_id.as_deref().expect("leader session"),
        );
        set_log_mtime_seconds_ago(&leader_log, 1_200);
        for agent in current
            .agents
            .values()
            .filter(|agent| agent.runtime == "codex")
        {
            write_agent_log_file(
                project,
                "codex",
                agent.agent_session_id.as_deref().expect("worker session"),
            );
        }

        let result = sync_agent_liveness("sync-promote-priority", project).expect("sync");
        assert_eq!(result.disconnected, vec![leader_id.clone()]);

        let updated = session_status("sync-promote-priority", project).expect("updated");
        let promoted = updated
            .leader_id
            .as_deref()
            .and_then(|agent_id| updated.agents.get(agent_id))
            .expect("promoted leader");
        assert_eq!(updated.status, SessionStatus::Active);
        assert_eq!(promoted.agent_id, preferred_id);
        assert_eq!(promoted.role, SessionRole::Leader);
    });
}

#[test]
fn sync_liveness_returns_dead_agent_task_to_open() {
    with_temp_project(|project| {
        let state = start_active_session("test", "", project, Some("claude"), Some("sync-3"))
            .expect("start");
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
        // Ack the task-start signal so it leaves the pending dir; an unacked
        // signal would keep the worker in Idle and prevent the disconnect
        // transition this test is exercising.
        accept_task_start_signal("sync-3", &worker_id, project);
        update_task(
            "sync-3",
            &task.task_id,
            TaskStatus::InProgress,
            None,
            &worker_id,
            project,
        )
        .expect("start");
        age_agent_activity(project, "sync-3", &worker_id, 1_200);

        // Make the worker agent stale
        let log_path = write_agent_log_file(project, "codex", "worker-sess-3");
        set_log_mtime_seconds_ago(&log_path, 1_200);

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
        start_active_session("test", "", project, Some("claude"), Some("sync-4")).expect("start");

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
        let state = session_status("sync-4", project).expect("status");
        for worker in state
            .agents
            .values()
            .filter(|agent| agent.runtime == "codex")
        {
            age_agent_activity(project, "sync-4", &worker.agent_id, 1_200);
        }
        for i in 1..=6 {
            let log_path = write_agent_log_file(project, "codex", &format!("worker-{i}"));
            set_log_mtime_seconds_ago(&log_path, 1_200);
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
        start_active_session("test", "", project, Some("claude"), Some("sync-noop"))
            .expect("start");
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
        let state = start_active_session("test", "", project, Some("claude"), Some("leave-1"))
            .expect("start");
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
fn leave_session_promotes_highest_priority_successor() {
    with_temp_project(|project| {
        let state = start_active_session_with_policy(
            "test",
            "",
            project,
            Some("claude"),
            Some("leave-promote"),
            Some("swarm-default"),
        )
        .expect("start");
        let leader_id = state.leader_id.clone().expect("leader");

        temp_env::with_var("CODEX_SESSION_ID", Some("improver-leave"), || {
            join_session(
                "leave-promote",
                SessionRole::Improver,
                "codex",
                &["priority:90".into()],
                Some("Improver"),
                project,
                None,
            )
            .expect("join improver");
        });

        leave_session("leave-promote", &leader_id, project).expect("leader leave");

        let updated = session_status("leave-promote", project).expect("status");
        let new_leader = updated
            .leader_id
            .as_deref()
            .and_then(|agent_id| updated.agents.get(agent_id))
            .expect("promoted leader");
        assert_eq!(updated.status, SessionStatus::Active);
        assert_eq!(new_leader.runtime, "codex");
        assert_eq!(new_leader.role, SessionRole::Leader);
    });
}

#[test]
fn leave_session_marks_session_leaderless_degraded_without_successor() {
    with_temp_project(|project| {
        let state = start_active_session_with_policy(
            "test",
            "",
            project,
            Some("claude"),
            Some("leave-degraded"),
            Some("swarm-default"),
        )
        .expect("start");
        let leader_id = state.leader_id.clone().expect("leader");

        leave_session("leave-degraded", &leader_id, project).expect("leader leave");

        let updated = session_status("leave-degraded", project).expect("status");
        assert_eq!(updated.status, SessionStatus::LeaderlessDegraded);
        assert!(
            updated.leader_id.is_none(),
            "no replacement leader should exist"
        );
        assert_eq!(
            updated.agents.get(&leader_id).expect("leader").status,
            AgentStatus::Disconnected
        );
    });
}
