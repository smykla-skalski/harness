use super::*;

#[test]
fn drop_task_to_same_agent_after_assign_starts_instead_of_self_queueing() {
    with_temp_project(|project| {
        let session_id = "drop-self-target";
        let state =
            start_active_session("test", "", project, Some("claude"), Some(session_id))
                .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("self-target-worker"))], || {
            join_session(
                session_id,
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join")
        });
        let worker_id = joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("worker id")
            .clone();
        let task = create_task(
            session_id,
            "self-target",
            Some("drop on the agent already holding this task"),
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("task");

        assign_task(session_id, &task.task_id, &worker_id, &leader_id, project).expect("assign");

        drop_task(
            session_id,
            &task.task_id,
            &protocol::TaskDropTarget::Agent {
                agent_id: worker_id.clone(),
            },
            TaskQueuePolicy::Locked,
            &leader_id,
            project,
        )
        .expect("drop");

        let state = session_status(session_id, project).expect("status");
        let task = state.tasks.get(&task.task_id).expect("task");
        assert_eq!(task.status, TaskStatus::Open);
        assert_eq!(task.assigned_to.as_deref(), Some(worker_id.as_str()));
        assert!(
            task.queued_at.is_none(),
            "task must not be queued behind itself"
        );
        let signals = list_signals(session_id, Some(&worker_id), project).expect("signals");
        let start_signal = signals
            .iter()
            .find(|record| record.signal.command == START_TASK_SIGNAL_COMMAND)
            .expect("start signal must be produced when dropping task back onto its assignee");
        let expected_action_hint = task_start_action_hint(&task.task_id);
        assert_eq!(
            start_signal.signal.payload.action_hint.as_deref(),
            Some(expected_action_hint.as_str())
        );
    });
}
