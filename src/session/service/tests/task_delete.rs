use super::*;

#[test]
fn delete_task_tombstones_hides_and_logs_it() {
    with_temp_project(|project| {
        let state = start_active_session(
            "delete task",
            "",
            project,
            Some("claude"),
            Some("task-delete"),
        )
        .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("delete-worker"))], || {
            join_session(
                "task-delete",
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
            "task-delete",
            "remove stale task",
            Some("delete should preserve history but hide the task"),
            TaskSeverity::High,
            &leader_id,
            project,
        )
        .expect("task");

        assign_task(
            "task-delete",
            &task.task_id,
            &worker_id,
            &leader_id,
            project,
        )
        .expect("assign");
        delete_task("task-delete", &task.task_id, &leader_id, project).expect("delete");

        let state = session_status("task-delete", project).expect("status");
        let deleted = state.tasks.get(&task.task_id).expect("deleted task");
        assert!(deleted.is_deleted());
        assert_eq!(deleted.status, TaskStatus::Done);
        assert!(deleted.assigned_to.is_none());
        assert!(deleted.queued_at.is_none());
        assert!(deleted.deleted_at.is_some());

        let worker = state.agents.get(&worker_id).expect("worker");
        assert!(worker.current_task_id.is_none());

        let visible = list_tasks("task-delete", None, project).expect("visible tasks");
        assert!(visible.is_empty());

        let layout = storage::layout_from_project_dir(project, "task-delete").expect("layout");
        let entries = storage::load_log_entries(&layout).expect("entries");
        let deleted_entry = entries
            .iter()
            .find(|entry| matches!(entry.transition, SessionTransition::TaskDeleted { .. }))
            .expect("task deleted entry");
        assert!(matches!(
            &deleted_entry.transition,
            SessionTransition::TaskDeleted {
                task_id,
                title,
                previous_status
            } if task_id == &task.task_id
                && title == "remove stale task"
                && *previous_status == TaskStatus::Open
        ));
    });
}

#[test]
fn delete_task_advances_queued_work_for_freed_worker() {
    with_temp_project(|project| {
        let state = start_active_session(
            "delete task queue",
            "",
            project,
            Some("claude"),
            Some("delete-task-queue"),
        )
        .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("queue-worker"))], || {
            join_session(
                "delete-task-queue",
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

        let active = create_task(
            "delete-task-queue",
            "active task",
            Some("worker starts here"),
            TaskSeverity::High,
            &leader_id,
            project,
        )
        .expect("active task");
        assign_task(
            "delete-task-queue",
            &active.task_id,
            &worker_id,
            &leader_id,
            project,
        )
        .expect("assign active");

        let queued = create_task(
            "delete-task-queue",
            "queued task",
            Some("should start after delete"),
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("queued task");
        assign_task(
            "delete-task-queue",
            &queued.task_id,
            &worker_id,
            &leader_id,
            project,
        )
        .expect("queue task");

        delete_task("delete-task-queue", &active.task_id, &leader_id, project).expect("delete");

        let state = session_status("delete-task-queue", project).expect("status");
        let worker = state.agents.get(&worker_id).expect("worker");
        assert_eq!(
            worker.current_task_id.as_deref(),
            Some(queued.task_id.as_str())
        );

        let queued_task = state.tasks.get(&queued.task_id).expect("queued task state");
        assert_eq!(queued_task.status, TaskStatus::Open);
        assert_eq!(queued_task.assigned_to.as_deref(), Some(worker_id.as_str()));
        assert!(queued_task.queued_at.is_none());
    });
}

#[test]
fn observer_can_delete_task_in_leaderless_degraded_session() {
    with_temp_project(|project| {
        start_active_session(
            "degraded observer delete",
            "",
            project,
            Some("claude"),
            Some("degraded-observer-delete"),
        )
        .expect("start");
        let joined = temp_env::with_var("CODEX_SESSION_ID", Some("degraded-delete-observer"), || {
            join_session(
                "degraded-observer-delete",
                SessionRole::Observer,
                "codex",
                &["triage".into()],
                Some("observer"),
                project,
                None,
            )
        })
        .expect("join observer");
        let observer_id = joined
            .agents
            .values()
            .find(|agent| agent.role == SessionRole::Observer)
            .expect("observer")
            .agent_id
            .clone();

        let layout =
            storage::layout_from_project_dir(project, "degraded-observer-delete").expect("layout");
        storage::update_state(&layout, |state| {
            let previous_leader = state.leader_id.take().expect("leader");
            state.status = SessionStatus::LeaderlessDegraded;
            let leader = state
                .agents
                .get_mut(&previous_leader)
                .expect("leader registration");
            leader.status = AgentStatus::disconnected_unknown();
            Ok(())
        })
        .expect("degrade session");

        let task = create_task(
            "degraded-observer-delete",
            "remove degraded finding",
            Some("observer should still manage task controls"),
            TaskSeverity::High,
            &observer_id,
            project,
        )
        .expect("create task");

        delete_task("degraded-observer-delete", &task.task_id, &observer_id, project)
            .expect("observer deletes task");

        let state = session_status("degraded-observer-delete", project).expect("status");
        assert_eq!(state.status, SessionStatus::LeaderlessDegraded);
        let deleted = state.tasks.get(&task.task_id).expect("deleted task");
        assert!(deleted.is_deleted());
        assert!(list_tasks("degraded-observer-delete", None, project)
            .expect("visible tasks")
            .is_empty());
    });
}
