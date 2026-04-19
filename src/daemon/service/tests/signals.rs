use super::*;

#[test]
fn send_signal_returns_detail_with_pending_signal() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon signal request",
            "",
            project,
            Some("claude"),
            Some("daemon-signal"),
        )
        .expect("start session");
        let leader_id = state.leader_id.expect("leader id");
        let joined =
            temp_env::with_vars([("CODEX_SESSION_ID", Some("daemon-signal-worker"))], || {
                session_service::join_session(
                    "daemon-signal",
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join worker")
            });
        let worker_id = joined
            .agents
            .keys()
            .find(|agent_id| agent_id.starts_with("codex-"))
            .expect("worker id")
            .clone();

        let detail = send_signal(
            "daemon-signal",
            &SignalSendRequest {
                actor: leader_id,
                agent_id: worker_id.clone(),
                command: "inject_context".into(),
                message: "Investigate the stuck signal lane".into(),
                action_hint: Some("task:signal".into()),
            },
            None,
            None,
        )
        .expect("send signal");

        assert_eq!(detail.session.session_id, "daemon-signal");
        assert_eq!(detail.signals.len(), 1);
        assert_eq!(detail.signals[0].agent_id, worker_id);
        assert_eq!(detail.signals[0].status, SessionSignalStatus::Pending);
        assert_eq!(detail.signals[0].signal.command, "inject_context");
        assert_eq!(
            detail.signals[0].signal.payload.message,
            "Investigate the stuck signal lane"
        );
        assert_eq!(
            detail.signals[0].signal.payload.action_hint.as_deref(),
            Some("task:signal")
        );
    });
}

#[test]
fn send_signal_db_direct_actively_delivers_to_idle_tui_agent() {
    with_temp_project(|project| {
        use crate::daemon::protocol::{SessionJoinRequest, SessionStartRequest};

        let db = Arc::new(Mutex::new(setup_db_with_project(project)));
        let db_slot = Arc::new(OnceLock::new());
        db_slot.set(Arc::clone(&db)).expect("db slot");
        let (sender, _) = broadcast::channel(8);
        let manager = AgentTuiManagerHandle::new(sender, db_slot, false);

        {
            let db_guard = db.lock().expect("db lock");
            start_session_direct(
                &SessionStartRequest {
                    title: "daemon active signal".into(),
                    context: "wake idle tui".into(),
                    runtime: "claude".into(),
                    session_id: Some("daemon-active-signal".into()),
                    project_dir: project.to_string_lossy().into(),
                    policy_preset: None,
                },
                Some(&db_guard),
            )
            .expect("start session");
        }

        let worker_session_id = "daemon-active-signal-worker";
        let signal_dir = runtime::runtime_for_name("codex")
            .expect("codex runtime")
            .signal_dir(project, worker_session_id);
        let script_path = write_idle_signal_script(
            project,
            &signal_dir,
            worker_session_id,
            "daemon-active-signal",
            IdleSignalScriptBehavior::AckOnWake,
        );

        let snapshot = manager
            .start(
                "daemon-active-signal",
                &AgentTuiStartRequest {
                    runtime: "codex".into(),
                    role: SessionRole::Worker,
                    fallback_role: None,
                    capabilities: vec![],
                    name: Some("idle worker".into()),
                    prompt: None,
                    project_dir: Some(project.to_string_lossy().into()),
                    argv: vec!["sh".into(), script_path.to_string_lossy().into_owned()],
                    rows: 5,
                    cols: 40,
                    persona: None,
                    model: None,
},
            )
            .expect("start agent tui");
        // Simulate the SessionStart hook callback.
        manager
            .signal_ready(&snapshot.tui_id)
            .expect("signal ready");

        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some(worker_session_id))], || {
            let db_guard = db.lock().expect("db lock");
            join_session_direct(
                "daemon-active-signal",
                &SessionJoinRequest {
                    runtime: "codex".into(),
                    role: SessionRole::Worker,
                    fallback_role: None,
                    capabilities: vec![
                        "agent-tui".into(),
                        format!("agent-tui:{}", snapshot.tui_id),
                    ],
                    name: Some("idle worker".into()),
                    project_dir: project.to_string_lossy().into(),
                    persona: None,
                },
                Some(&db_guard),
            )
            .expect("join worker")
        });
        let worker_id = joined
            .agents
            .values()
            .find(|agent| agent.role == SessionRole::Worker)
            .expect("worker agent")
            .agent_id
            .clone();

        let detail = {
            let db_guard = db.lock().expect("db lock");
            send_signal(
                "daemon-active-signal",
                &SignalSendRequest {
                    actor: joined.leader_id.clone().expect("leader id"),
                    agent_id: worker_id.clone(),
                    command: "inject_context".into(),
                    message: "deliver immediately".into(),
                    action_hint: Some("task:active".into()),
                },
                Some(&db_guard),
                Some(&manager),
            )
            .expect("send signal")
        };

        let signal = detail
            .signals
            .iter()
            .find(|signal| {
                signal.agent_id == worker_id
                    && signal.signal.payload.message == "deliver immediately"
            })
            .expect("delivered signal");
        assert_eq!(signal.status, SessionSignalStatus::Delivered);
        assert_eq!(
            signal.acknowledgment.as_ref().map(|ack| ack.result),
            Some(AckResult::Accepted)
        );
    });
}

#[test]
fn send_signal_db_direct_warns_when_idle_tui_ack_times_out() {
    with_temp_project(|project| {
        use crate::daemon::protocol::{SessionJoinRequest, SessionStartRequest};

        let db = Arc::new(Mutex::new(setup_db_with_project(project)));
        let db_slot = Arc::new(OnceLock::new());
        db_slot.set(Arc::clone(&db)).expect("db slot");
        let (sender, _) = broadcast::channel(8);
        let manager = AgentTuiManagerHandle::new(sender, db_slot, false);

        {
            let db_guard = db.lock().expect("db lock");
            start_session_direct(
                &SessionStartRequest {
                    title: "daemon timed signal".into(),
                    context: "warn when idle tui ignores wake".into(),
                    runtime: "claude".into(),
                    session_id: Some("daemon-timed-signal".into()),
                    project_dir: project.to_string_lossy().into(),
                    policy_preset: None,
                },
                Some(&db_guard),
            )
            .expect("start session");
        }

        let worker_session_id = "daemon-timed-signal-worker";
        let signal_dir = runtime::runtime_for_name("codex")
            .expect("codex runtime")
            .signal_dir(project, worker_session_id);
        let script_path = write_idle_signal_script(
            project,
            &signal_dir,
            worker_session_id,
            "daemon-timed-signal",
            IdleSignalScriptBehavior::IgnoreWake,
        );

        let snapshot = manager
            .start(
                "daemon-timed-signal",
                &AgentTuiStartRequest {
                    runtime: "codex".into(),
                    role: SessionRole::Worker,
                    fallback_role: None,
                    capabilities: vec![],
                    name: Some("sleepy worker".into()),
                    prompt: None,
                    project_dir: Some(project.to_string_lossy().into()),
                    argv: vec!["sh".into(), script_path.to_string_lossy().into_owned()],
                    rows: 5,
                    cols: 40,
                    persona: None,
                    model: None,
},
            )
            .expect("start agent tui");
        manager
            .signal_ready(&snapshot.tui_id)
            .expect("signal ready");

        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some(worker_session_id))], || {
            let db_guard = db.lock().expect("db lock");
            join_session_direct(
                "daemon-timed-signal",
                &SessionJoinRequest {
                    runtime: "codex".into(),
                    role: SessionRole::Worker,
                    fallback_role: None,
                    capabilities: vec![
                        "agent-tui".into(),
                        format!("agent-tui:{}", snapshot.tui_id),
                    ],
                    name: Some("sleepy worker".into()),
                    project_dir: project.to_string_lossy().into(),
                    persona: None,
                },
                Some(&db_guard),
            )
            .expect("join worker")
        });
        let worker_id = joined
            .agents
            .values()
            .find(|agent| agent.role == SessionRole::Worker)
            .expect("worker agent")
            .agent_id
            .clone();

        let detail = {
            let db_guard = db.lock().expect("db lock");
            send_signal(
                "daemon-timed-signal",
                &SignalSendRequest {
                    actor: joined.leader_id.clone().expect("leader id"),
                    agent_id: worker_id.clone(),
                    command: "inject_context".into(),
                    message: "stay pending".into(),
                    action_hint: Some("task:warn".into()),
                },
                Some(&db_guard),
                Some(&manager),
            )
            .expect("send signal")
        };

        let signal = detail
            .signals
            .iter()
            .find(|signal| {
                signal.agent_id == worker_id && signal.signal.payload.message == "stay pending"
            })
            .expect("pending signal");
        assert_eq!(signal.status, SessionSignalStatus::Pending);

        let events = state::read_recent_events(1).expect("read daemon events");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].level, "warn");
        assert!(
            events[0].message.contains("daemon-timed-signal")
                && events[0].message.contains(&worker_id),
            "warning should mention session and agent: {}",
            events[0].message
        );
    });
}

#[test]
fn cancel_signal_flips_status_to_rejected_and_logs_entry() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon cancel request",
            "",
            project,
            Some("claude"),
            Some("daemon-cancel"),
        )
        .expect("start session");
        let leader_id = state.leader_id.expect("leader id");
        let joined =
            temp_env::with_vars([("CODEX_SESSION_ID", Some("daemon-cancel-worker"))], || {
                session_service::join_session(
                    "daemon-cancel",
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join worker")
            });
        let worker_id = joined
            .agents
            .keys()
            .find(|agent_id| agent_id.starts_with("codex-"))
            .expect("worker id")
            .clone();

        let sent = send_signal(
            "daemon-cancel",
            &SignalSendRequest {
                actor: leader_id.clone(),
                agent_id: worker_id.clone(),
                command: "inject_context".into(),
                message: "Investigate the stuck signal lane".into(),
                action_hint: Some("task:signal".into()),
            },
            None,
            None,
        )
        .expect("send signal");
        let signal_id = sent.signals[0].signal.signal_id.clone();

        let detail = cancel_signal(
            "daemon-cancel",
            &super::super::protocol::SignalCancelRequest {
                actor: leader_id,
                agent_id: worker_id.clone(),
                signal_id: signal_id.clone(),
            },
            None,
        )
        .expect("cancel signal");

        assert_eq!(detail.signals.len(), 1);
        assert_eq!(detail.signals[0].status, SessionSignalStatus::Rejected);
        assert_eq!(detail.signals[0].signal.signal_id, signal_id);
        assert_eq!(
            detail.signals[0]
                .acknowledgment
                .as_ref()
                .map(|ack| ack.result),
            Some(crate::agents::runtime::signal::AckResult::Rejected)
        );

        let log_entries =
            crate::session::storage::load_log_entries(project, "daemon-cancel").expect("log");
        assert!(log_entries.into_iter().any(|entry| matches!(
            entry.transition,
            crate::session::types::SessionTransition::SignalAcknowledged {
                signal_id: ref id,
                result: crate::agents::runtime::signal::AckResult::Rejected,
                ..
            } if id == &signal_id
        )));
    });
}

#[test]
fn cancel_signal_errors_when_signal_not_pending() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon cancel missing",
            "",
            project,
            Some("claude"),
            Some("daemon-cancel-missing"),
        )
        .expect("start session");
        let leader_id = state.leader_id.expect("leader id");
        let joined = temp_env::with_vars(
            [("CODEX_SESSION_ID", Some("daemon-cancel-missing-worker"))],
            || {
                session_service::join_session(
                    "daemon-cancel-missing",
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join worker")
            },
        );
        let worker_id = joined
            .agents
            .keys()
            .find(|agent_id| agent_id.starts_with("codex-"))
            .expect("worker id")
            .clone();

        let result = cancel_signal(
            "daemon-cancel-missing",
            &super::super::protocol::SignalCancelRequest {
                actor: leader_id,
                agent_id: worker_id,
                signal_id: "nonexistent-signal".into(),
            },
            None,
        );

        assert!(result.is_err(), "cancel should fail when signal missing");
    });
}
