use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use tempfile::tempdir;

use crate::agents::runtime::signal::AckResult;
use crate::daemon::protocol::{
    SessionJoinRequest, SignalAckRequest, SignalCancelRequest, SignalSendRequest,
};
use crate::session::types::{SessionRole, SessionSignalStatus};
use harness_testkit::with_isolated_harness_env;

use super::async_mutations::{
    init_git_project, start_async_http_session, test_http_state_with_empty_async_db,
};
use super::*;

async fn join_http_worker(
    state: &DaemonHttpState,
    session_id: &str,
    project_dir: &std::path::Path,
    name: &str,
) -> String {
    let response = post_session_join(
        axum::extract::Path(session_id.to_owned()),
        auth_headers(),
        State(state.clone()),
        Json(SessionJoinRequest {
            runtime: "codex".into(),
            role: SessionRole::Worker,
            capabilities: vec!["general".into()],
            name: Some(name.to_string()),
            project_dir: project_dir.to_string_lossy().into_owned(),
            persona: None,
        }),
    )
    .await;
    let (status, _) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);

    let async_db = state.async_db.get().expect("async db");
    let resolved = async_db
        .resolve_session(session_id)
        .await
        .expect("resolve session")
        .expect("session present");
    resolved
        .state
        .agents
        .keys()
        .find(|agent_id| agent_id.starts_with("codex-"))
        .expect("worker id")
        .to_string()
}

async fn leader_id_for_session(state: &DaemonHttpState, session_id: &str) -> String {
    let async_db = state.async_db.get().expect("async db");
    let resolved = async_db
        .resolve_session(session_id)
        .await
        .expect("resolve session")
        .expect("session present");
    resolved.state.leader_id.expect("leader id")
}

async fn seed_pending_signal(
    state: &DaemonHttpState,
    session_id: &str,
    actor_id: &str,
    agent_id: &str,
    project_dir: &std::path::Path,
    message: &str,
) -> String {
    let async_db = state.async_db.get().expect("async db");
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
        &crate::workspace::utc_now(),
    );
    let signal_session_id = agent.agent_session_id.as_deref().unwrap_or(session_id);
    runtime
        .write_signal(project_dir, signal_session_id, &signal)
        .expect("write signal");
    signal.signal_id
}

#[test]
fn post_cancel_signal_uses_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("http-async-signal-cancel-leader")),
                ("CODEX_SESSION_ID", Some("http-async-signal-cancel-worker")),
            ],
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);

                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    let _ = start_async_http_session(
                        state.clone(),
                        &project_dir,
                        "http-async-signal-cancel",
                    )
                    .await;
                    let worker_id = join_http_worker(
                        &state,
                        "http-async-signal-cancel",
                        &project_dir,
                        "Async Signal Worker",
                    )
                    .await;
                    let leader_id = leader_id_for_session(&state, "http-async-signal-cancel").await;

                    let signal_id = seed_pending_signal(
                        &state,
                        "http-async-signal-cancel",
                        &leader_id,
                        &worker_id,
                        &project_dir,
                        "async cancel me",
                    )
                    .await;

                    let response = post_cancel_signal(
                        axum::extract::Path("http-async-signal-cancel".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(SignalCancelRequest {
                            actor: "spoofed".into(),
                            agent_id: worker_id,
                            signal_id: signal_id.clone(),
                        }),
                    )
                    .await;

                    let (status, body) = response_json(response).await;
                    assert_eq!(status, StatusCode::OK);
                    assert_eq!(
                        body["signals"][0]["signal"]["signal_id"].as_str(),
                        Some(signal_id.as_str())
                    );
                    assert_eq!(body["signals"][0]["status"].as_str(), Some("rejected"));
                });
            },
        );
    });
}

#[test]
fn post_send_signal_uses_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("http-async-signal-send-leader")),
                ("CODEX_SESSION_ID", Some("http-async-signal-send-worker")),
            ],
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);

                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    let _ = start_async_http_session(
                        state.clone(),
                        &project_dir,
                        "http-async-signal-send",
                    )
                    .await;
                    let worker_id = join_http_worker(
                        &state,
                        "http-async-signal-send",
                        &project_dir,
                        "Async Send Worker",
                    )
                    .await;
                    let leader_id = leader_id_for_session(&state, "http-async-signal-send").await;

                    let response = post_send_signal(
                        axum::extract::Path("http-async-signal-send".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(SignalSendRequest {
                            actor: leader_id,
                            agent_id: worker_id.clone(),
                            command: "inject_context".into(),
                            message: "async send me".into(),
                            action_hint: Some("task:http-async-signal".into()),
                        }),
                    )
                    .await;

                    let (status, body) = response_json(response).await;
                    assert_eq!(status, StatusCode::OK);
                    let signal = body["signals"]
                        .as_array()
                        .and_then(|signals| signals.first())
                        .expect("signal response");
                    assert_eq!(signal["agent_id"].as_str(), Some(worker_id.as_str()));
                    assert_eq!(signal["status"].as_str(), Some("pending"));
                    assert_eq!(
                        signal["signal"]["payload"]["message"].as_str(),
                        Some("async send me")
                    );
                });
            },
        );
    });
}

#[test]
fn post_signal_ack_uses_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("http-async-signal-ack-leader")),
                ("CODEX_SESSION_ID", Some("http-async-signal-ack-worker")),
            ],
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);

                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    let _ = start_async_http_session(
                        state.clone(),
                        &project_dir,
                        "http-async-signal-ack",
                    )
                    .await;
                    let worker_id = join_http_worker(
                        &state,
                        "http-async-signal-ack",
                        &project_dir,
                        "Async Ack Worker",
                    )
                    .await;
                    let leader_id = leader_id_for_session(&state, "http-async-signal-ack").await;

                    let signal_id = seed_pending_signal(
                        &state,
                        "http-async-signal-ack",
                        &leader_id,
                        &worker_id,
                        &project_dir,
                        "async ack me",
                    )
                    .await;

                    let response = post_signal_ack(
                        axum::extract::Path("http-async-signal-ack".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(SignalAckRequest {
                            agent_id: worker_id.clone(),
                            signal_id: signal_id.clone(),
                            result: AckResult::Rejected,
                            project_dir: project_dir.to_string_lossy().into_owned(),
                        }),
                    )
                    .await;

                    let (status, body) = response_json(response).await;
                    assert_eq!(status, StatusCode::OK);
                    assert_eq!(body["ok"].as_bool(), Some(true));

                    let async_db = state.async_db.get().expect("async db");
                    let record = async_db
                        .load_signals("http-async-signal-ack")
                        .await
                        .expect("load signals")
                        .into_iter()
                        .find(|signal| signal.signal.signal_id == signal_id)
                        .expect("signal record");
                    assert_eq!(record.status, SessionSignalStatus::Rejected);
                    assert_eq!(
                        record.acknowledgment.as_ref().map(|ack| ack.result),
                        Some(AckResult::Rejected)
                    );
                    assert_eq!(record.agent_id, worker_id);
                });
            },
        );
    });
}
