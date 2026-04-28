use super::*;

#[test]
fn remove_agent_returns_tasks() {
    with_temp_project(|project| {
        let state =
            start_active_session("test", "", project, Some("claude"), Some("s4")).expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = join_session("s4", SessionRole::Worker, "codex", &[], None, project, None)
            .expect("join");
        let worker_id = joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex"))
            .expect("worker id")
            .clone();

        let task = create_task(
            "s4",
            "task1",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("task");
        assign_task("s4", &task.task_id, &worker_id, &leader_id, project).expect("assign");
        remove_agent("s4", &worker_id, &leader_id, project).expect("remove");

        let tasks = list_tasks("s4", Some(TaskStatus::Open), project).expect("open");
        assert_eq!(tasks.len(), 1);
        assert!(tasks[0].assigned_to.is_none());
    });
}

#[test]
fn drop_task_queues_for_busy_worker() {
    with_temp_project(|project| {
        let state =
            start_active_session("test", "", project, Some("claude"), Some("drop-queue-busy"))
                .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("busy-worker"))], || {
            join_session(
                "drop-queue-busy",
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
            "drop-queue-busy",
            "active",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("active");
        assign_task(
            "drop-queue-busy",
            &active.task_id,
            &worker_id,
            &leader_id,
            project,
        )
        .expect("assign active");
        let queued = create_task(
            "drop-queue-busy",
            "queued",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("queued");

        drop_task(
            "drop-queue-busy",
            &queued.task_id,
            &protocol::TaskDropTarget::Agent {
                agent_id: worker_id.clone(),
            },
            TaskQueuePolicy::Locked,
            &leader_id,
            project,
        )
        .expect("drop");

        let state = session_status("drop-queue-busy", project).expect("status");
        let queued_task = state.tasks.get(&queued.task_id).expect("queued task");
        assert_eq!(queued_task.status, TaskStatus::Open);
        assert_eq!(queued_task.assigned_to.as_deref(), Some(worker_id.as_str()));
        assert_eq!(queued_task.queue_policy, TaskQueuePolicy::Locked);
        assert!(queued_task.queued_at.is_some());
        let worker = state.agents.get(&worker_id).expect("worker");
        assert_eq!(
            worker.current_task_id.as_deref(),
            Some(active.task_id.as_str())
        );
    });
}

#[test]
fn reassignable_drop_starts_on_free_worker() {
    with_temp_project(|project| {
        let state = start_active_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("drop-reassign-free"),
        )
        .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let first_joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("busy-worker"))], || {
            join_session(
                "drop-reassign-free",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join busy")
        });
        let busy_worker = first_joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("busy worker")
            .clone();
        let second_joined =
            temp_env::with_vars([("CODEX_SESSION_ID", Some("free-worker"))], || {
                join_session(
                    "drop-reassign-free",
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join free")
            });
        let free_worker = second_joined
            .agents
            .keys()
            .filter(|id| id.starts_with("codex-"))
            .find(|id| *id != &busy_worker)
            .expect("free worker")
            .clone();
        let active = create_task(
            "drop-reassign-free",
            "active",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("active");
        assign_task(
            "drop-reassign-free",
            &active.task_id,
            &busy_worker,
            &leader_id,
            project,
        )
        .expect("assign active");
        let task = create_task(
            "drop-reassign-free",
            "reassignable",
            Some("pick up immediately"),
            TaskSeverity::High,
            &leader_id,
            project,
        )
        .expect("task");

        drop_task(
            "drop-reassign-free",
            &task.task_id,
            &protocol::TaskDropTarget::Agent {
                agent_id: busy_worker.clone(),
            },
            TaskQueuePolicy::ReassignWhenFree,
            &leader_id,
            project,
        )
        .expect("drop");

        let state = session_status("drop-reassign-free", project).expect("status");
        let started = state.tasks.get(&task.task_id).expect("started task");
        assert_eq!(started.status, TaskStatus::Open);
        assert_eq!(started.assigned_to.as_deref(), Some(free_worker.as_str()));
        assert!(started.queued_at.is_none());
        let worker = state.agents.get(&free_worker).expect("worker");
        assert_eq!(
            worker.current_task_id.as_deref(),
            Some(task.task_id.as_str()),
            "current_task_id is locked on this task while the start signal is in flight"
        );
        let signals =
            list_signals("drop-reassign-free", Some(&free_worker), project).expect("signals");
        assert_eq!(signals.len(), 1);
        assert_eq!(signals[0].signal.command, START_TASK_SIGNAL_COMMAND);
        let expected_action_hint = task_start_action_hint(&task.task_id);
        assert_eq!(
            signals[0].signal.payload.action_hint.as_deref(),
            Some(expected_action_hint.as_str())
        );
    });
}

#[test]
fn observer_can_create_task_in_leaderless_degraded_session() {
    with_temp_project(|project| {
        start_active_session(
            "degraded observer triage",
            "",
            project,
            Some("claude"),
            Some("degraded-observer-task"),
        )
        .expect("start");
        let joined = temp_env::with_var("CODEX_SESSION_ID", Some("degraded-observer"), || {
            join_session(
                "degraded-observer-task",
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
            storage::layout_from_project_dir(project, "degraded-observer-task").expect("layout");
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
            "degraded-observer-task",
            "capture degraded finding",
            Some("observer should still be able to record triage"),
            TaskSeverity::High,
            &observer_id,
            project,
        )
        .expect("observer creates task in degraded session");

        let state = session_status("degraded-observer-task", project).expect("status");
        assert_eq!(state.status, SessionStatus::LeaderlessDegraded);
        assert_eq!(state.tasks.len(), 1);
        assert_eq!(
            state.tasks[&task.task_id].created_by.as_deref(),
            Some(observer_id.as_str())
        );
    });
}

#[test]
fn locked_queue_advances_when_worker_finishes_current_task() {
    with_temp_project(|project| {
        let state = start_active_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("drop-advance-locked"),
        )
        .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("advance-worker"))], || {
            join_session(
                "drop-advance-locked",
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
            "drop-advance-locked",
            "active",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("active");
        assign_task(
            "drop-advance-locked",
            &active.task_id,
            &worker_id,
            &leader_id,
            project,
        )
        .expect("assign active");
        let queued = create_task(
            "drop-advance-locked",
            "queued",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("queued");
        drop_task(
            "drop-advance-locked",
            &queued.task_id,
            &protocol::TaskDropTarget::Agent {
                agent_id: worker_id.clone(),
            },
            TaskQueuePolicy::Locked,
            &leader_id,
            project,
        )
        .expect("drop");

        update_task(
            "drop-advance-locked",
            &active.task_id,
            TaskStatus::Done,
            Some("done"),
            &leader_id,
            project,
        )
        .expect("finish");

        let state = session_status("drop-advance-locked", project).expect("status");
        let next = state.tasks.get(&queued.task_id).expect("next task");
        assert_eq!(next.status, TaskStatus::Open);
        assert_eq!(next.assigned_to.as_deref(), Some(worker_id.as_str()));
        let worker = state.agents.get(&worker_id).expect("worker");
        assert_eq!(
            worker.current_task_id.as_deref(),
            Some(next.task_id.as_str()),
            "advancing the queue locks the worker on the newly started task"
        );
    });
}

#[test]
fn task_start_signal_acceptance_marks_task_in_progress() {
    with_temp_project(|project| {
        let state =
            start_active_session("test", "", project, Some("claude"), Some("drop-ack-accept"))
                .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("accept-worker"))], || {
            join_session(
                "drop-ack-accept",
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
        let worker = joined.agents.get(&worker_id).expect("worker");
        let task = create_task(
            "drop-ack-accept",
            "queued",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("queued");

        drop_task(
            "drop-ack-accept",
            &task.task_id,
            &protocol::TaskDropTarget::Agent {
                agent_id: worker_id.clone(),
            },
            TaskQueuePolicy::Locked,
            &leader_id,
            project,
        )
        .expect("drop");

        let signal =
            list_signals("drop-ack-accept", Some(&worker_id), project).expect("signals")[0].clone();
        let runtime = runtime::runtime_for_name(worker.runtime.runtime_name()).expect("runtime");
        let worker_session_id = worker.agent_session_id.clone().expect("worker session id");
        let signal_dir = runtime.signal_dir(project, &worker_session_id);
        let ack = SignalAck {
            signal_id: signal.signal.signal_id.clone(),
            acknowledged_at: utc_now(),
            result: AckResult::Accepted,
            agent: worker_session_id,
            session_id: "drop-ack-accept".into(),
            details: None,
        };

        runtime::signal::acknowledge_signal(&signal_dir, &ack).expect("ack");
        record_signal_acknowledgment(
            "drop-ack-accept",
            &worker_id,
            &signal.signal.signal_id,
            AckResult::Accepted,
            project,
        )
        .expect("record ack");

        let state = session_status("drop-ack-accept", project).expect("status");
        let task = state.tasks.get(&task.task_id).expect("task");
        assert_eq!(task.status, TaskStatus::InProgress);
        assert_eq!(task.assigned_to.as_deref(), Some(worker_id.as_str()));
        let worker = state.agents.get(&worker_id).expect("worker");
        assert_eq!(
            worker.current_task_id.as_deref(),
            Some(task.task_id.as_str())
        );
    });
}
