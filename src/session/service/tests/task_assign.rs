use super::*;

#[test]
fn assign_task_keeps_task_open_until_worker_starts() {
    with_temp_project(|project| {
        let state = start_active_session("test", "", project, Some("claude"), Some("assign-open"))
            .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("assign-worker"))], || {
            join_session(
                "assign-open",
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
            "assign-open",
            "observer follow-up",
            Some("wait for the worker to actually start"),
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("task");

        assign_task(
            "assign-open",
            &task.task_id,
            &worker_id,
            &leader_id,
            project,
        )
        .expect("assign");

        let state = session_status("assign-open", project).expect("status");
        let task = state.tasks.get(&task.task_id).expect("task");
        assert_eq!(task.status, TaskStatus::Open);
        assert_eq!(task.assigned_to.as_deref(), Some(worker_id.as_str()));
        assert!(task.queued_at.is_none());
        let worker = state.agents.get(&worker_id).expect("worker");
        assert_eq!(
            worker.current_task_id.as_deref(),
            Some(task.task_id.as_str()),
            "current_task_id is locked on this task while the start signal is in flight"
        );
        let signals = list_signals("assign-open", Some(&worker_id), project).expect("signals");
        let start_signal = signals
            .iter()
            .find(|record| record.signal.command == START_TASK_SIGNAL_COMMAND)
            .expect("assign on a free worker must produce a task-start signal");
        let expected_action_hint = task_start_action_hint(&task.task_id);
        assert_eq!(
            start_signal.signal.payload.action_hint.as_deref(),
            Some(expected_action_hint.as_str())
        );
    });
}
