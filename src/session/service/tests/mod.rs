use super::*;
use harness_testkit::with_isolated_harness_env;

mod support;
#[allow(unused_imports)]
use support::*;

mod basics;
mod leave_signals;
mod liveness;
mod liveness_interactive;
mod permissions;
mod review_guards;
mod signal_reconciliation;
mod signals;
mod state;
mod task_drop_self_target;
mod task_flow;

#[test]
fn session_service_round_trip_smoke_covers_public_surface() {
    with_temp_project(|project| {
        let session_id = "service-smoke";
        let state = start_active_session(
            "smoke goal",
            "Smoke",
            project,
            Some("claude"),
            Some(session_id),
        )
        .expect("start");
        let leader_id = state.leader_id.clone().expect("leader id");
        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("smoke-worker"))], || {
            join_session(
                session_id,
                SessionRole::Worker,
                "codex",
                &["general".to_string()],
                Some("worker"),
                project,
                None,
            )
        })
        .expect("join");
        let worker_id = joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("worker id")
            .clone();
        let worker = joined.agents.get(&worker_id).expect("worker");
        let worker_session_id = worker.agent_session_id.clone().expect("worker session id");
        let resolved = resolve_session_agent_for_runtime_session(project, "codex", "smoke-worker")
            .expect("resolve")
            .expect("session mapping");
        assert_eq!(resolved.orchestration_session_id, session_id);
        assert_eq!(resolved.agent_id, worker_id);

        let task = create_task_with_source(
            session_id,
            &TaskSpec {
                title: "investigate drift",
                context: Some("triage the failing path"),
                severity: TaskSeverity::High,
                suggested_fix: Some("reproduce and narrow the regression"),
                source: TaskSource::Manual,
                observe_issue_id: None,
            },
            &leader_id,
            project,
        )
        .expect("create task");
        record_task_checkpoint(
            session_id,
            &task.task_id,
            &leader_id,
            "triaged",
            40,
            project,
        )
        .expect("checkpoint");
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
        .expect("drop task");

        let start_signal = list_signals(session_id, Some(&worker_id), project)
            .expect("signals")
            .into_iter()
            .find(|record| record.signal.command == START_TASK_SIGNAL_COMMAND)
            .expect("start signal");
        let signal_dir = runtime::runtime_for_name(&worker.runtime)
            .expect("runtime")
            .signal_dir(project, &worker_session_id);
        runtime::signal::acknowledge_signal(
            &signal_dir,
            &SignalAck {
                signal_id: start_signal.signal.signal_id.clone(),
                acknowledged_at: utc_now(),
                result: AckResult::Accepted,
                agent: worker_session_id.clone(),
                session_id: session_id.to_string(),
                details: None,
            },
        )
        .expect("ack");
        record_signal_acknowledgment(
            session_id,
            &worker_id,
            &start_signal.signal.signal_id,
            AckResult::Accepted,
            project,
        )
        .expect("record ack");

        let manual_signal = send_signal(
            session_id,
            &worker_id,
            "inject_context",
            "new instructions",
            Some("review task"),
            &leader_id,
            project,
        )
        .expect("send signal");
        cancel_signal(
            session_id,
            &worker_id,
            &manual_signal.signal.signal_id,
            &leader_id,
            project,
        )
        .expect("cancel signal");
        update_task(
            session_id,
            &task.task_id,
            TaskStatus::Done,
            Some("done"),
            &leader_id,
            project,
        )
        .expect("complete task");
        leave_session(session_id, &worker_id, project).expect("leave");

        let status = session_status(session_id, project).expect("status");
        assert_eq!(status.tasks[&task.task_id].status, TaskStatus::Done);
        assert_eq!(status.agents[&worker_id].status, AgentStatus::Disconnected);
        assert_eq!(
            list_tasks(session_id, Some(TaskStatus::Done), project)
                .expect("done tasks")
                .len(),
            1
        );
        assert_eq!(list_sessions(project, false).expect("list").len(), 1);
        assert_eq!(
            resolve_session_project_dir(session_id, project).expect("resolve project dir"),
            project
        );
        assert!(
            list_signals(session_id, Some(&worker_id), project)
                .expect("final signals")
                .iter()
                .any(|record| {
                    record.signal.signal_id == manual_signal.signal.signal_id
                        && record.status == SessionSignalStatus::Rejected
                })
        );

        end_session(session_id, &leader_id, project).expect("end");
        assert_eq!(
            session_status(session_id, project)
                .expect("ended status")
                .status,
            SessionStatus::Ended
        );
    });
}
