use crate::agents::runtime::signal::AckResult;
use crate::daemon::protocol::{SignalAckRequest, SignalCancelRequest, SignalSendRequest};
use crate::session::types::{SessionRole, SessionSignalStatus};

use super::*;

async fn seed_pending_signal(
    async_db: &crate::daemon::db::AsyncDaemonDb,
    session_id: &str,
    actor_id: &str,
    agent_id: &str,
    project_dir: &std::path::Path,
    message: &str,
) -> String {
    let resolved = async_db
        .resolve_session(session_id)
        .await
        .expect("resolve session")
        .expect("session present");
    let agent = resolved
        .state
        .agents
        .get(agent_id)
        .expect("agent present")
        .clone();
    let runtime = crate::agents::runtime::runtime_for_name(&agent.runtime).expect("runtime");
    let signal = crate::session::service::build_signal(
        actor_id,
        "inject_context",
        message,
        Some("task:async-signal"),
        session_id,
        agent_id,
        &utc_now(),
    );
    let signal_session_id = agent.agent_session_id.as_deref().unwrap_or(session_id);
    runtime
        .write_signal(project_dir, signal_session_id, &signal)
        .expect("write signal");
    signal.signal_id
}

#[test]
fn send_signal_async_returns_detail_with_pending_signal_without_sync_handle() {
    with_temp_project(|project| {
        temp_env::with_var("CODEX_SESSION_ID", Some("async-signal-send-worker"), || {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let db_path = project
                    .parent()
                    .expect("project parent")
                    .join("daemon.sqlite");
                let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                    .await
                    .expect("open async daemon db");
                let state = start_session_direct_async(
                    &crate::daemon::protocol::SessionStartRequest {
                        title: "async signal send".into(),
                        context: "async signal send".into(),
                        runtime: "claude".into(),
                        session_id: Some("daemon-async-signal-send".into()),
                        project_dir: project.to_string_lossy().into(),
                        policy_preset: None,
                    },
                    &async_db,
                )
                .await
                .expect("start session");
                let leader_id = state.leader_id.clone().expect("leader id");
                let joined = join_session_direct_async(
                    "daemon-async-signal-send",
                    &crate::daemon::protocol::SessionJoinRequest {
                        runtime: "codex".into(),
                        role: SessionRole::Worker,
                        fallback_role: None,
                        capabilities: vec![],
                        name: None,
                        project_dir: project.to_string_lossy().into(),
                        persona: None,
                    },
                    &async_db,
                )
                .await
                .expect("join session");
                let worker_id = joined
                    .agents
                    .keys()
                    .find(|agent_id| agent_id.starts_with("codex-"))
                    .expect("worker id")
                    .to_string();

                let detail = send_signal_async(
                    "daemon-async-signal-send",
                    &SignalSendRequest {
                        actor: leader_id,
                        agent_id: worker_id.clone(),
                        command: "inject_context".into(),
                        message: "Investigate the async signal lane".into(),
                        action_hint: Some("task:async-signal".into()),
                    },
                    &async_db,
                    None,
                )
                .await
                .expect("send signal async");

                assert_eq!(detail.session.session_id, "daemon-async-signal-send");
                assert_eq!(detail.signals.len(), 1);
                assert_eq!(detail.signals[0].agent_id, worker_id);
                assert_eq!(detail.signals[0].status, SessionSignalStatus::Pending);
                assert_eq!(detail.signals[0].signal.command, "inject_context");
            });
        });
    });
}

#[test]
fn cancel_signal_async_updates_async_db_without_sync_handle() {
    with_temp_project(|project| {
        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("async-signal-cancel-worker"),
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = project
                        .parent()
                        .expect("project parent")
                        .join("daemon.sqlite");
                    let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                        .await
                        .expect("open async daemon db");
                    let state = start_session_direct_async(
                        &crate::daemon::protocol::SessionStartRequest {
                            title: "async signal cancel".into(),
                            context: "async signal cancel".into(),
                            runtime: "claude".into(),
                            session_id: Some("daemon-async-signal-cancel".into()),
                            project_dir: project.to_string_lossy().into(),
                            policy_preset: None,
                        },
                        &async_db,
                    )
                    .await
                    .expect("start session");
                    let leader_id = state.leader_id.clone().expect("leader id");
                    let joined = join_session_direct_async(
                        "daemon-async-signal-cancel",
                        &crate::daemon::protocol::SessionJoinRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Worker,
                            fallback_role: None,
                            capabilities: vec![],
                            name: None,
                            project_dir: project.to_string_lossy().into(),
                            persona: None,
                        },
                        &async_db,
                    )
                    .await
                    .expect("join session");
                    let worker_id = joined
                        .agents
                        .keys()
                        .find(|agent_id| agent_id.starts_with("codex-"))
                        .expect("worker id")
                        .to_string();

                    let signal_id = seed_pending_signal(
                        &async_db,
                        "daemon-async-signal-cancel",
                        &leader_id,
                        &worker_id,
                        project,
                        "cancel via async db",
                    )
                    .await;

                    let detail = cancel_signal_async(
                        "daemon-async-signal-cancel",
                        &SignalCancelRequest {
                            actor: leader_id,
                            agent_id: worker_id.clone(),
                            signal_id: signal_id.clone(),
                        },
                        &async_db,
                    )
                    .await
                    .expect("cancel via async db");

                    let signal = detail
                        .signals
                        .into_iter()
                        .find(|signal| signal.signal.signal_id == signal_id)
                        .expect("cancelled signal");
                    assert_eq!(signal.status, SessionSignalStatus::Rejected);
                    assert_eq!(
                        signal.acknowledgment.as_ref().map(|ack| ack.result),
                        Some(AckResult::Rejected)
                    );
                    assert_eq!(signal.agent_id, worker_id);
                });
            },
        );
    });
}

#[test]
fn record_signal_ack_direct_async_updates_signal_index_without_sync_handle() {
    with_temp_project(|project| {
        temp_env::with_var("CODEX_SESSION_ID", Some("async-signal-ack-worker"), || {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let db_path = project
                    .parent()
                    .expect("project parent")
                    .join("daemon.sqlite");
                let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                    .await
                    .expect("open async daemon db");
                let state = start_session_direct_async(
                    &crate::daemon::protocol::SessionStartRequest {
                        title: "async signal ack".into(),
                        context: "async signal ack".into(),
                        runtime: "claude".into(),
                        session_id: Some("daemon-async-signal-ack".into()),
                        project_dir: project.to_string_lossy().into(),
                        policy_preset: None,
                    },
                    &async_db,
                )
                .await
                .expect("start session");
                let leader_id = state.leader_id.clone().expect("leader id");
                let joined = join_session_direct_async(
                    "daemon-async-signal-ack",
                    &crate::daemon::protocol::SessionJoinRequest {
                        runtime: "codex".into(),
                        role: SessionRole::Worker,
                        fallback_role: None,
                        capabilities: vec![],
                        name: None,
                        project_dir: project.to_string_lossy().into(),
                        persona: None,
                    },
                    &async_db,
                )
                .await
                .expect("join session");
                let worker_id = joined
                    .agents
                    .keys()
                    .find(|agent_id| agent_id.starts_with("codex-"))
                    .expect("worker id")
                    .to_string();

                let signal_id = seed_pending_signal(
                    &async_db,
                    "daemon-async-signal-ack",
                    &leader_id,
                    &worker_id,
                    project,
                    "ack via async db",
                )
                .await;

                record_signal_ack_direct_async(
                    "daemon-async-signal-ack",
                    &SignalAckRequest {
                        agent_id: worker_id.clone(),
                        signal_id: signal_id.clone(),
                        result: AckResult::Rejected,
                        project_dir: project.to_string_lossy().into(),
                    },
                    &async_db,
                )
                .await
                .expect("record ack via async db");

                let detail = session_detail_async("daemon-async-signal-ack", Some(&async_db))
                    .await
                    .expect("load async detail");
                let signal = detail
                    .signals
                    .into_iter()
                    .find(|signal| signal.signal.signal_id == signal_id)
                    .expect("acknowledged signal");
                assert_eq!(signal.status, SessionSignalStatus::Rejected);
                assert_eq!(
                    signal.acknowledgment.as_ref().map(|ack| ack.result),
                    Some(AckResult::Rejected)
                );
                assert_eq!(signal.agent_id, worker_id);
            });
        });
    });
}

#[test]
fn session_detail_core_async_reopens_expired_pending_delivery_without_sync_handle() {
    with_temp_project(|project| {
        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("async-task-expired-worker"),
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = project
                        .parent()
                        .expect("project parent")
                        .join("daemon.sqlite");
                    let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                        .await
                        .expect("open async daemon db");
                    let state = start_session_direct_async(
                        &crate::daemon::protocol::SessionStartRequest {
                            title: "async signal expired".into(),
                            context: "async signal expired".into(),
                            runtime: "claude".into(),
                            session_id: Some("daemon-async-signal-expired".into()),
                            project_dir: project.to_string_lossy().into(),
                            policy_preset: None,
                        },
                        &async_db,
                    )
                    .await
                    .expect("start session");
                    let leader_id = state.leader_id.clone().expect("leader id");
                    let joined = join_session_direct_async(
                        "daemon-async-signal-expired",
                        &crate::daemon::protocol::SessionJoinRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Worker,
                            fallback_role: None,
                            capabilities: vec![],
                            name: None,
                            project_dir: project.to_string_lossy().into(),
                            persona: None,
                        },
                        &async_db,
                    )
                    .await
                    .expect("join session");
                    let worker_id = joined
                        .agents
                        .keys()
                        .find(|agent_id| agent_id.starts_with("codex-"))
                        .expect("worker id")
                        .to_string();

                    let created = create_task_async(
                        "daemon-async-signal-expired",
                        &TaskCreateRequest {
                            actor: leader_id.clone(),
                            title: "Expire before delivery".into(),
                            context: None,
                            severity: crate::session::types::TaskSeverity::Medium,
                            suggested_fix: None,
                        },
                        &async_db,
                    )
                    .await
                    .expect("create task");
                    let task_id = created.tasks[0].task_id.clone();

                    let dropped = drop_task_async(
                        "daemon-async-signal-expired",
                        &task_id,
                        &TaskDropRequest {
                            actor: leader_id,
                            target: crate::daemon::protocol::TaskDropTarget::Agent {
                                agent_id: worker_id.clone(),
                            },
                            queue_policy: crate::session::types::TaskQueuePolicy::Locked,
                        },
                        &async_db,
                    )
                    .await
                    .expect("drop task");

                    let signal = dropped
                        .signals
                        .iter()
                        .find(|signal| signal.agent_id == worker_id)
                        .expect("task signal")
                        .signal
                        .clone();
                    let runtime = runtime::runtime_for_name("codex").expect("codex runtime");
                    let signal_dir = runtime.signal_dir(project, "async-task-expired-worker");
                    let expired_signal = crate::agents::runtime::signal::Signal {
                        expires_at: "2000-01-01T00:00:00Z".into(),
                        ..signal
                    };
                    fs::write(
                        signal_dir
                            .join("pending")
                            .join(format!("{}.json", expired_signal.signal_id)),
                        serde_json::to_string_pretty(&expired_signal)
                            .expect("serialize expired signal"),
                    )
                    .expect("rewrite expired signal");
                    let resolved = async_db
                        .resolve_session("daemon-async-signal-expired")
                        .await
                        .expect("resolve session")
                        .expect("session present");
                    let signals = crate::daemon::snapshot::load_signals_for(
                        &resolved.project,
                        &resolved.state,
                    )
                    .expect("load signals");
                    async_db
                        .sync_signal_index("daemon-async-signal-expired", &signals)
                        .await
                        .expect("refresh signal index");

                    let core =
                        session_detail_core_async("daemon-async-signal-expired", Some(&async_db))
                            .await
                            .expect("core detail");
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
                        session_extensions_async("daemon-async-signal-expired", Some(&async_db))
                            .await
                            .expect("session extensions");
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
            },
        );
    });
}
