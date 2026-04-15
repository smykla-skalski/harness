use crate::agents::runtime::signal::AckResult;
use crate::daemon::protocol::{SignalAckRequest, SignalCancelRequest};
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
