use super::*;

#[test]
fn leave_session_marks_agent_disconnected() {
    with_temp_project(|project| {
        let state = start_active_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("00000000-0000-4002-8000-000000000016"),
        )
        .expect("start");
        let leader_id = state.leader_id.expect("leader");

        temp_env::with_var("CODEX_SESSION_ID", Some("worker-leave"), || {
            join_session(
                "00000000-0000-4002-8000-000000000016",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join");
        });

        let state =
            session_status("00000000-0000-4002-8000-000000000016", project).expect("status");
        let worker_id = find_agent_by_runtime(&state, "codex").agent_id.clone();

        let task = create_task(
            "00000000-0000-4002-8000-000000000016",
            "test task",
            Some("details"),
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("create task");
        assign_task(
            "00000000-0000-4002-8000-000000000016",
            &task.task_id,
            &worker_id,
            &leader_id,
            project,
        )
        .expect("00000000-0000-4002-8000-000000000005");

        leave_session("00000000-0000-4002-8000-000000000016", &worker_id, project).expect("leave");

        let state =
            session_status("00000000-0000-4002-8000-000000000016", project).expect("status");
        let worker = state.agents.get(&worker_id).expect("worker");
        assert_eq!(
            worker.status,
            AgentStatus::Disconnected {
                reason: crate::agents::kind::DisconnectReason::UserCancelled,
                stderr_tail: None,
            }
        );

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
            Some("00000000-0000-4002-8000-000000000018"),
            Some("swarm-default"),
        )
        .expect("start");
        let leader_id = state.leader_id.expect("leader");

        temp_env::with_var("CODEX_SESSION_ID", Some("improver-leave"), || {
            join_session(
                "00000000-0000-4002-8000-000000000018",
                SessionRole::Improver,
                "codex",
                &["priority:90".into()],
                Some("Improver"),
                project,
                None,
            )
            .expect("join improver");
        });

        leave_session("00000000-0000-4002-8000-000000000018", &leader_id, project)
            .expect("leader leave");

        let updated =
            session_status("00000000-0000-4002-8000-000000000018", project).expect("status");
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
            Some("00000000-0000-4002-8000-000000000017"),
            Some("swarm-default"),
        )
        .expect("start");
        let leader_id = state.leader_id.expect("leader");

        leave_session("00000000-0000-4002-8000-000000000017", &leader_id, project)
            .expect("leader leave");

        let updated =
            session_status("00000000-0000-4002-8000-000000000017", project).expect("status");
        assert_eq!(updated.status, SessionStatus::LeaderlessDegraded);
        assert!(
            updated.leader_id.is_none(),
            "no replacement leader should exist"
        );
        assert_eq!(
            updated.agents.get(&leader_id).expect("leader").status,
            AgentStatus::Disconnected {
                reason: crate::agents::kind::DisconnectReason::UserCancelled,
                stderr_tail: None,
            }
        );
    });
}
