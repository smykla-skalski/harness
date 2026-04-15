use super::*;
use std::{fs, path::PathBuf};

#[test]
fn send_signal_db_direct_refreshes_non_empty_signal_index() {
    with_temp_project(|project| {
        let (db, state) = setup_db_only_session(project);
        let leader_id = state.leader_id.clone().expect("leader id");

        let first = send_signal(
            &state.session_id,
            &SignalSendRequest {
                actor: leader_id.clone(),
                agent_id: leader_id.clone(),
                command: "inject_context".into(),
                message: "first signal".into(),
                action_hint: None,
            },
            Some(&db),
            None,
        )
        .expect("first signal");
        assert_eq!(first.signals.len(), 1);

        let second = send_signal(
            &state.session_id,
            &SignalSendRequest {
                actor: leader_id.clone(),
                agent_id: leader_id,
                command: "inject_context".into(),
                message: "second signal".into(),
                action_hint: None,
            },
            Some(&db),
            None,
        )
        .expect("second signal");

        assert_eq!(second.signals.len(), 2);
        let messages: Vec<_> = second
            .signals
            .iter()
            .map(|signal| signal.signal.payload.message.as_str())
            .collect();
        assert!(messages.contains(&"first signal"));
        assert!(messages.contains(&"second signal"));
    });
}

#[test]
fn task_start_ack_db_direct_starts_work_only_after_delivery() {
    with_temp_project(|project| {
        let (db, state) = setup_db_only_session(project);
        let leader_id = state.leader_id.clone().expect("leader id");
        let worker_session_id = "db-task-delivery-worker";
        let worker_id = join_db_codex_worker(&db, &state, project, worker_session_id);

        let created = create_task(
            &state.session_id,
            &TaskCreateRequest {
                actor: leader_id.clone(),
                title: "Start after delivery".into(),
                context: None,
                severity: crate::session::types::TaskSeverity::Medium,
                suggested_fix: None,
            },
            Some(&db),
        )
        .expect("create task");
        let task_id = created.tasks[0].task_id.clone();

        let dropped = drop_task(
            &state.session_id,
            &task_id,
            &TaskDropRequest {
                actor: leader_id,
                target: super::super::protocol::TaskDropTarget::Agent {
                    agent_id: worker_id.clone(),
                },
                queue_policy: crate::session::types::TaskQueuePolicy::Locked,
            },
            Some(&db),
        )
        .expect("drop task");

        let pending_task = dropped
            .tasks
            .iter()
            .find(|task| task.task_id == task_id)
            .expect("pending task");
        assert_eq!(pending_task.status, crate::session::types::TaskStatus::Open);
        assert_eq!(
            pending_task.assigned_to.as_deref(),
            Some(worker_id.as_str())
        );
        assert!(pending_task.queued_at.is_none());
        let worker = dropped
            .agents
            .iter()
            .find(|agent| agent.agent_id == worker_id)
            .expect("worker");
        assert!(worker.current_task_id.is_none());
        assert!(
            !db.load_session_log(&state.session_id)
                .expect("session log")
                .into_iter()
                .any(|entry| matches!(
                    entry.transition,
                    SessionTransition::TaskAssigned { ref task_id, ref agent_id }
                        if task_id == &pending_task.task_id && agent_id == &worker_id
                ))
        );

        let signal = dropped
            .signals
            .iter()
            .find(|signal| signal.agent_id == worker_id)
            .expect("task signal");
        let signal_id = signal.signal.signal_id.clone();
        let runtime = runtime::runtime_for_name(&signal.runtime).expect("task runtime");
        let signal_dir = runtime.signal_dir(project, worker_session_id);
        let _pending_signal = require_pending_signal_path(&signal_dir, &signal_id);
        runtime::signal::acknowledge_signal(
            &signal_dir,
            &SignalAck {
                signal_id: signal_id.clone(),
                acknowledged_at: utc_now(),
                result: AckResult::Accepted,
                agent: worker_session_id.to_string(),
                session_id: state.session_id.clone(),
                details: None,
            },
        )
        .expect("write signal ack");

        record_signal_ack_direct(
            &state.session_id,
            &super::super::protocol::SignalAckRequest {
                agent_id: worker_id.clone(),
                signal_id,
                result: AckResult::Accepted,
                project_dir: project.to_string_lossy().into_owned(),
            },
            Some(&db),
        )
        .expect("record signal ack");

        let detail = session_detail(&state.session_id, Some(&db)).expect("session detail");
        let active_task = detail
            .tasks
            .iter()
            .find(|task| task.task_id == task_id)
            .expect("active task");
        assert_eq!(
            active_task.status,
            crate::session::types::TaskStatus::InProgress
        );
        let worker = detail
            .agents
            .iter()
            .find(|agent| agent.agent_id == worker_id)
            .expect("worker");
        assert_eq!(worker.current_task_id.as_deref(), Some(task_id.as_str()));
        assert!(
            detail
                .signals
                .iter()
                .any(|signal| signal.status == SessionSignalStatus::Delivered)
        );
        assert!(
            db.load_session_log(&state.session_id)
                .expect("session log")
                .into_iter()
                .any(|entry| matches!(
                    entry.transition,
                    SessionTransition::TaskAssigned { ref task_id, ref agent_id }
                        if task_id == &active_task.task_id && agent_id == &worker_id
                ))
        );
    });
}

#[test]
fn session_detail_core_db_direct_reopens_expired_pending_delivery() {
    with_temp_project(|project| {
        let (db, state) = setup_db_only_session(project);
        let leader_id = state.leader_id.clone().expect("leader id");
        let worker_session_id = "db-task-expired-worker";
        let worker_id = join_db_codex_worker(&db, &state, project, worker_session_id);

        let created = create_task(
            &state.session_id,
            &TaskCreateRequest {
                actor: leader_id.clone(),
                title: "Expire before delivery".into(),
                context: None,
                severity: crate::session::types::TaskSeverity::Medium,
                suggested_fix: None,
            },
            Some(&db),
        )
        .expect("create task");
        let task_id = created.tasks[0].task_id.clone();

        let dropped = drop_task(
            &state.session_id,
            &task_id,
            &TaskDropRequest {
                actor: leader_id,
                target: super::super::protocol::TaskDropTarget::Agent {
                    agent_id: worker_id.clone(),
                },
                queue_policy: crate::session::types::TaskQueuePolicy::Locked,
            },
            Some(&db),
        )
        .expect("drop task");

        let signal = dropped
            .signals
            .iter()
            .find(|signal| signal.agent_id == worker_id)
            .expect("task signal");
        let runtime = runtime::runtime_for_name(&signal.runtime).expect("task runtime");
        let signal_dir = runtime.signal_dir(project, worker_session_id);
        let pending_signal = require_pending_signal_path(&signal_dir, &signal.signal.signal_id);
        let expired_signal = crate::agents::runtime::signal::Signal {
            expires_at: "2000-01-01T00:00:00Z".into(),
            ..signal.signal.clone()
        };
        fs::write(
            pending_signal,
            serde_json::to_string_pretty(&expired_signal).expect("serialize expired signal"),
        )
        .expect("rewrite expired signal");
        let resolved = db
            .resolve_session(&state.session_id)
            .expect("resolve session")
            .expect("session present");
        let signals = crate::daemon::snapshot::load_signals_for(&resolved.project, &resolved.state)
            .expect("load signals");
        db.sync_signal_index(&state.session_id, &signals)
            .expect("refresh signal index");

        let core = session_detail_core(&state.session_id, Some(&db)).expect("core detail");
        let reopened_task = core
            .tasks
            .iter()
            .find(|task| task.task_id == task_id)
            .expect("reopened task");
        assert_eq!(
            reopened_task.status,
            crate::session::types::TaskStatus::Open
        );
        assert!(reopened_task.assigned_to.is_none());
        let worker = core
            .agents
            .iter()
            .find(|agent| agent.agent_id == worker_id)
            .expect("worker");
        assert!(worker.current_task_id.is_none());

        let extensions =
            session_extensions(&state.session_id, Some(&db)).expect("session extensions");
        let signal = extensions
            .signals
            .expect("signals")
            .into_iter()
            .find(|signal| signal.agent_id == worker_id)
            .expect("expired signal");
        assert_eq!(signal.status, SessionSignalStatus::Expired);
        assert_eq!(
            signal.acknowledgment.expect("ack").result,
            AckResult::Expired
        );
    });
}

fn require_pending_signal_path(signal_dir: &std::path::Path, signal_id: &str) -> PathBuf {
    let pending = signal_dir.join("pending").join(format!("{signal_id}.json"));
    if pending.is_file() {
        return pending;
    }

    let siblings = signal_dir
        .parent()
        .and_then(|parent| fs::read_dir(parent).ok())
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .map(|entry| entry.path().display().to_string())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let project_roots = signal_dir
        .ancestors()
        .nth(4)
        .and_then(|project_root| project_root.parent())
        .and_then(|projects_root| fs::read_dir(projects_root).ok())
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .map(|entry| entry.path().display().to_string())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    panic!(
        "missing pending signal at {}; sibling runtime-session dirs: {:?}; project roots: {:?}",
        pending.display(),
        siblings,
        project_roots
    );
}
