use super::*;

#[test]
fn list_sessions_returns_all_when_requested() {
    with_temp_project(|project| {
        let first = start_active_session(
            "goal1",
            "",
            project,
            Some("claude"),
            Some("00000000-0000-4002-8000-00000000001a"),
        )
        .expect("start one");
        start_active_session(
            "goal2",
            "",
            project,
            Some("codex"),
            Some("00000000-0000-4002-8000-00000000003f"),
        )
        .expect("start two");
        end_session(
            "00000000-0000-4002-8000-00000000001a",
            first.leader_id.as_deref().expect("leader"),
            project,
        )
        .expect("end");

        let active_only = list_sessions(project, false).expect("active list");
        let all_sessions = list_sessions(project, true).expect("all list");
        assert_eq!(active_only.len(), 1);
        assert_eq!(all_sessions.len(), 2);
    });
}

#[test]
fn list_sessions_default_visibility_includes_awaiting_leader_active_and_leaderless_degraded() {
    with_temp_project(|project| {
        start_session(
            "goal-awaiting",
            "",
            project,
            Some("00000000-0000-4002-8000-000000000019"),
        )
        .expect("start awaiting");
        start_active_session(
            "goal-active",
            "",
            project,
            Some("claude"),
            Some("00000000-0000-4002-8000-00000000003e"),
        )
        .expect("start active");
        let degraded = start_active_session(
            "goal-degraded",
            "",
            project,
            Some("claude"),
            Some("00000000-0000-4002-8000-000000000042"),
        )
        .expect("start degraded");
        let degraded_leader = degraded.leader_id.expect("degraded leader");
        let degraded_layout =
            storage::layout_from_project_dir(project, "00000000-0000-4002-8000-000000000042")
                .expect("degraded layout");
        storage::update_state(&degraded_layout, |state| {
            state.status = SessionStatus::LeaderlessDegraded;
            state.leader_id = None;
            state
                .agents
                .get_mut(&degraded_leader)
                .expect("degraded leader")
                .status = AgentStatus::disconnected_unknown();
            Ok(())
        })
        .expect("degrade session");

        let ended = start_active_session(
            "goal-ended",
            "",
            project,
            Some("claude"),
            Some("00000000-0000-4002-8000-000000000043"),
        )
        .expect("start ended");
        end_session(
            "00000000-0000-4002-8000-000000000043",
            ended.leader_id.as_deref().expect("leader"),
            project,
        )
        .expect("end session");

        let visible_ids = list_sessions(project, false)
            .expect("default list")
            .into_iter()
            .map(|state| state.session_id)
            .collect::<Vec<_>>();
        assert!(
            visible_ids
                .iter()
                .any(|id| id == "00000000-0000-4002-8000-000000000019")
        );
        assert!(
            visible_ids
                .iter()
                .any(|id| id == "00000000-0000-4002-8000-00000000003e")
        );
        assert!(
            visible_ids
                .iter()
                .any(|id| id == "00000000-0000-4002-8000-000000000042")
        );
        assert!(
            !visible_ids
                .iter()
                .any(|id| id == "00000000-0000-4002-8000-000000000043")
        );

        let all_ids = list_sessions(project, true)
            .expect("all list")
            .into_iter()
            .map(|state| state.session_id)
            .collect::<Vec<_>>();
        assert!(
            all_ids
                .iter()
                .any(|id| id == "00000000-0000-4002-8000-000000000019")
        );
        assert!(
            all_ids
                .iter()
                .any(|id| id == "00000000-0000-4002-8000-00000000003e")
        );
        assert!(
            all_ids
                .iter()
                .any(|id| id == "00000000-0000-4002-8000-000000000042")
        );
        assert!(
            all_ids
                .iter()
                .any(|id| id == "00000000-0000-4002-8000-000000000043")
        );
    });
}

#[test]
fn checkpoint_record_updates_task_summary_and_log() {
    with_temp_project(|project| {
        let state = start_active_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("00000000-0000-4002-8000-000000000025"),
        )
        .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let task = create_task(
            "00000000-0000-4002-8000-000000000025",
            "watch daemon",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("task");

        let checkpoint = record_task_checkpoint(
            "00000000-0000-4002-8000-000000000025",
            &task.task_id,
            &leader_id,
            "watcher attached",
            35,
            project,
        )
        .expect("checkpoint");

        let updated =
            session_status("00000000-0000-4002-8000-000000000025", project).expect("status");
        let stored_task = updated.tasks.get(&task.task_id).expect("stored task");
        assert_eq!(
            stored_task
                .checkpoint_summary
                .as_ref()
                .expect("summary")
                .progress,
            35
        );

        let layout =
            storage::layout_from_project_dir(project, "00000000-0000-4002-8000-000000000025")
                .expect("layout");
        let checkpoints =
            storage::load_task_checkpoints(&layout, &task.task_id).expect("checkpoints");
        assert_eq!(checkpoints.len(), 1);
        assert_eq!(checkpoints[0].checkpoint_id, checkpoint.checkpoint_id);
    });
}

#[test]
fn send_signal_lists_pending_signal_for_target_agent() {
    with_temp_project(|project| {
        let state = start_active_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("00000000-0000-4002-8000-000000000027"),
        )
        .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = join_session(
            "00000000-0000-4002-8000-000000000027",
            SessionRole::Worker,
            "codex",
            &[],
            None,
            project,
            None,
        )
        .expect("join");
        let worker_id = joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex"))
            .expect("worker id")
            .clone();

        send_signal(
            "00000000-0000-4002-8000-000000000027",
            &worker_id,
            "inject_context",
            "new task queued",
            Some("review task-1"),
            &leader_id,
            project,
        )
        .expect("signal");

        let signals = list_signals(
            "00000000-0000-4002-8000-000000000027",
            Some(&worker_id),
            project,
        )
        .expect("signals");
        assert_eq!(signals.len(), 1);
        assert_eq!(signals[0].status, SessionSignalStatus::Pending);
        assert_eq!(signals[0].runtime, "codex");
        assert_eq!(signals[0].signal.command, "inject_context");
    });
}

#[test]
fn list_signals_filters_shared_runtime_session_history() {
    with_temp_project(|project| {
        let session_one = start_active_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("00000000-0000-4002-8000-000000000026"),
        )
        .expect("start alpha");
        let leader_one = session_one.leader_id.expect("alpha leader id");
        let joined_one = temp_env::with_vars([("CODEX_SESSION_ID", Some("codex-shared"))], || {
            join_session(
                "00000000-0000-4002-8000-000000000026",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join alpha worker")
        });
        let worker_one = joined_one
            .agents
            .keys()
            .find(|id| id.starts_with("codex"))
            .expect("alpha worker id")
            .clone();

        let session_two = start_active_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("00000000-0000-4002-8000-000000000040"),
        )
        .expect("start beta");
        let leader_two = session_two.leader_id.expect("beta leader id");
        let joined_two = temp_env::with_vars([("CODEX_SESSION_ID", Some("codex-shared"))], || {
            join_session(
                "00000000-0000-4002-8000-000000000040",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join beta worker")
        });
        let worker_two = joined_two
            .agents
            .keys()
            .find(|id| id.starts_with("codex"))
            .expect("beta worker id")
            .clone();

        send_signal(
            "00000000-0000-4002-8000-000000000026",
            &worker_one,
            "inject_context",
            "alpha task queued",
            Some("review alpha"),
            &leader_one,
            project,
        )
        .expect("alpha signal");
        send_signal(
            "00000000-0000-4002-8000-000000000040",
            &worker_two,
            "inject_context",
            "beta task queued",
            Some("review beta"),
            &leader_two,
            project,
        )
        .expect("beta signal");

        let alpha_signals = list_signals(
            "00000000-0000-4002-8000-000000000026",
            Some(&worker_one),
            project,
        )
        .expect("alpha signals");
        let beta_signals = list_signals(
            "00000000-0000-4002-8000-000000000040",
            Some(&worker_two),
            project,
        )
        .expect("beta signals");

        assert_eq!(alpha_signals.len(), 1);
        assert_eq!(alpha_signals[0].signal.payload.message, "alpha task queued");
        assert_eq!(beta_signals.len(), 1);
        assert_eq!(beta_signals[0].signal.payload.message, "beta task queued");
    });
}

#[test]
fn send_signal_denies_worker_actor() {
    with_temp_project(|project| {
        start_active_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("00000000-0000-4002-8000-000000000028"),
        )
        .expect("start");
        let joined = join_session(
            "00000000-0000-4002-8000-000000000028",
            SessionRole::Worker,
            "codex",
            &[],
            None,
            project,
            None,
        )
        .expect("join");
        let worker_id = joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex"))
            .expect("worker id")
            .clone();

        let error = send_signal(
            "00000000-0000-4002-8000-000000000028",
            &worker_id,
            "inject_context",
            "workers should not send signals",
            None,
            &worker_id,
            project,
        )
        .expect_err("permission denied");

        assert_eq!(error.code(), "KSRCLI091");
    });
}
