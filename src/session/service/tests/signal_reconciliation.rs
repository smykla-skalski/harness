use super::*;

#[test]
fn expired_task_start_signal_reopens_task_and_clears_assignment() {
    with_temp_project(|project| {
        let state =
            start_session("test", "", project, Some("claude"), Some("drop-expire")).expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("expire-worker"))], || {
            join_session(
                "drop-expire",
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
            "drop-expire",
            "queued",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("queued");

        drop_task(
            "drop-expire",
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
            list_signals("drop-expire", Some(&worker_id), project).expect("signals")[0].clone();
        let runtime = runtime::runtime_for_name(&worker.runtime).expect("runtime");
        let signal_dir = runtime.signal_dir(
            project,
            worker
                .agent_session_id
                .as_deref()
                .expect("worker session id"),
        );
        let signal_id = signal.signal.signal_id.clone();
        let expired_signal = Signal {
            expires_at: "2000-01-01T00:00:00Z".into(),
            ..signal.signal
        };
        let pending_path =
            runtime::signal::pending_dir(&signal_dir).join(format!("{signal_id}.json"));
        std::fs::write(
            &pending_path,
            serde_json::to_string_pretty(&expired_signal).expect("serialize expired signal"),
        )
        .expect("rewrite expired signal");

        let state = session_status("drop-expire", project).expect("status");
        let task = state.tasks.get(&task.task_id).expect("task");
        assert_eq!(task.status, TaskStatus::Open);
        assert!(task.assigned_to.is_none());
        let worker = state.agents.get(&worker_id).expect("worker");
        assert!(worker.current_task_id.is_none());

        let signals = list_signals("drop-expire", Some(&worker_id), project).expect("signals");
        assert_eq!(signals.len(), 1);
        assert_eq!(signals[0].status, SessionSignalStatus::Expired);
        assert_eq!(
            signals[0]
                .acknowledgment
                .as_ref()
                .expect("expired acknowledgment")
                .result,
            AckResult::Expired
        );
    });
}

#[test]
fn collect_expired_pending_signals_resolves_context_root_once_per_pass() {
    with_temp_project(|project| {
        let state = start_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("signal-root-once"),
        )
        .expect("start");
        let joined =
            temp_env::with_vars([("CODEX_SESSION_ID", Some("signal-root-worker"))], || {
                join_session(
                    "signal-root-once",
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join")
            });
        let resolver_calls = std::cell::Cell::new(0usize);

        let expired = collect_expired_pending_signals_for_state_with_context_root_resolver(
            &joined,
            project,
            |path| {
                resolver_calls.set(resolver_calls.get() + 1);
                crate::workspace::project_context_dir(path)
            },
        )
        .expect("collect expired");

        assert!(
            expired.is_empty(),
            "fresh session should not contain expired signals"
        );
        assert_eq!(resolver_calls.get(), 1);
        assert_eq!(state.session_id, joined.session_id);
    });
}
