use super::*;

#[test]
fn end_session_sends_abort_leave_signal_and_disconnects_agents() {
    with_temp_project(|project| {
        let state = start_active_session("test", "", project, Some("claude"), Some("end-leave"))
            .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("end-leave-worker"))], || {
            join_session(
                "end-leave",
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

        end_session("end-leave", &leader_id, project).expect("end");

        let updated = session_status("end-leave", project).expect("status");
        assert_eq!(updated.status, SessionStatus::Ended);
        assert_eq!(updated.metrics.active_agent_count, 0);
        assert!(updated.pending_leader_transfer.is_none());
        assert!(
            updated
                .agents
                .values()
                .all(|agent| { agent.status.is_disconnected() && agent.current_task_id.is_none() })
        );

        let signals = list_signals("end-leave", None, project).expect("signals");
        assert_eq!(signals.len(), 2);
        assert!(signals.iter().all(|record| {
            record.status == SessionSignalStatus::Pending
                && record.signal.command == LEAVE_SESSION_SIGNAL_COMMAND
                && record
                    .signal
                    .payload
                    .message
                    .contains("leave the harness session")
                && record.signal.payload.action_hint.as_deref()
                    == Some(END_SESSION_SIGNAL_ACTION_HINT)
        }));
        assert!(signals.iter().any(|record| record.agent_id == leader_id));
        assert!(signals.iter().any(|record| record.agent_id == worker_id));

        let layout = storage::layout_from_project_dir(project, "end-leave").expect("layout");
        let entries = storage::load_log_entries(&layout).expect("entries");
        assert_eq!(
            entries
                .iter()
                .filter(|entry| {
                    matches!(
                        entry.transition,
                        SessionTransition::SignalSent { ref command, .. }
                            if command == LEAVE_SESSION_SIGNAL_COMMAND
                    )
                })
                .count(),
            2
        );
        assert!(
            entries
                .iter()
                .any(|entry| matches!(entry.transition, SessionTransition::SessionEnded))
        );
    });
}

#[test]
fn remove_agent_sends_abort_leave_signal_to_removed_agent() {
    with_temp_project(|project| {
        let state = start_active_session("test", "", project, Some("claude"), Some("remove-leave"))
            .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined =
            temp_env::with_vars([("CODEX_SESSION_ID", Some("remove-leave-worker"))], || {
                join_session(
                    "remove-leave",
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

        remove_agent("remove-leave", &worker_id, &leader_id, project).expect("remove");

        let updated = session_status("remove-leave", project).expect("status");
        let worker = updated.agents.get(&worker_id).expect("worker");
        assert_eq!(worker.status, AgentStatus::Removed);
        assert!(worker.current_task_id.is_none());

        let signals =
            list_signals("remove-leave", Some(&worker_id), project).expect("worker signals");
        assert_eq!(signals.len(), 1);
        assert_eq!(signals[0].status, SessionSignalStatus::Pending);
        assert_eq!(signals[0].signal.command, LEAVE_SESSION_SIGNAL_COMMAND);
        assert_eq!(
            signals[0].signal.payload.action_hint.as_deref(),
            Some(REMOVE_AGENT_SIGNAL_ACTION_HINT)
        );
        assert!(
            signals[0]
                .signal
                .payload
                .message
                .contains("leave the harness session")
        );
    });
}

#[test]
fn end_session_fails_visibly_when_leave_signal_cannot_be_delivered() {
    with_temp_project(|project| {
        let state =
            start_active_session("test", "", project, Some("claude"), Some("end-leave-fail"))
                .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = join_session(
            "end-leave-fail",
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
            .find(|id| id.starts_with("codex-"))
            .expect("worker id")
            .clone();
        let layout = storage::layout_from_project_dir(project, "end-leave-fail").expect("layout");
        storage::update_state(&layout, |state| {
            state.agents.get_mut(&worker_id).expect("worker").runtime = "unknown".into();
            Ok(())
        })
        .expect("mark invalid runtime");

        let error = end_session("end-leave-fail", &leader_id, project).expect_err("end fails");

        assert_eq!(error.code(), "KSRCLI092");
        let message = error.to_string();
        assert!(message.contains("leave signal delivery failed"));
        assert!(message.contains("needs attention"));
        let updated = session_status("end-leave-fail", project).expect("status");
        assert_eq!(updated.status, SessionStatus::Active);
        assert_eq!(updated.metrics.active_agent_count, 2);
        assert!(
            list_signals("end-leave-fail", None, project)
                .expect("signals")
                .is_empty()
        );
    });
}
