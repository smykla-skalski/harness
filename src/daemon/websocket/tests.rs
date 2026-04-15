use axum::extract::ws::Message;
use fs_err as fs;
use std::path::Path;
use std::process::Command;
use std::sync::OnceLock;
use std::sync::{Arc, Mutex};
use tempfile::tempdir;
use tokio::sync::broadcast;

use super::ReplayBuffer;
use super::connection::ConnectionState;
use super::dispatch::dispatch;
use super::frames::serialize_response_frames;
use super::queries::{dispatch_read_query, handle_session_subscribe, handle_stream_subscribe};
use super::test_support::{
    seed_sample_timeline, test_http_state_with_async_db_timeline, test_http_state_with_db,
};
use crate::agents::runtime::runtime_for_name;
use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::http::{AsyncDaemonDbSlot, DaemonHttpState};
use crate::daemon::protocol::{SessionJoinRequest, SessionStartRequest, WsRequest, WsResponse};
use crate::daemon::service::{join_session_direct_async, start_session_direct_async};
use crate::daemon::state::DaemonManifest;
use crate::session::service::build_signal;
use crate::session::types::{SessionRole, SessionSignalStatus};
use crate::workspace::utc_now;
use harness_testkit::with_isolated_harness_env;

pub(super) async fn test_websocket_state_with_empty_async_db(db_path: &Path) -> DaemonHttpState {
    let (sender, _) = broadcast::channel(8);
    let db_slot = Arc::new(OnceLock::new());
    let async_db_slot = Arc::new(OnceLock::new());

    assert!(
        async_db_slot
            .set(Arc::new(
                AsyncDaemonDb::connect(db_path)
                    .await
                    .expect("open async daemon db"),
            ))
            .is_ok(),
        "install async db"
    );

    let manifest: DaemonManifest = serde_json::from_value(serde_json::json!({
        "version": "20.6.0",
        "pid": 1,
        "endpoint": "http://127.0.0.1:0",
        "started_at": "2026-04-13T00:00:00Z",
        "token_path": "/tmp/token",
        "sandboxed": false,
        "host_bridge": {},
        "revision": 0,
        "updated_at": "",
        "binary_stamp": null,
    }))
    .expect("deserialize daemon manifest");

    DaemonHttpState {
        token: "token".into(),
        sender: sender.clone(),
        manifest,
        daemon_epoch: "epoch".into(),
        replay_buffer: Arc::new(Mutex::new(ReplayBuffer::new(8))),
        db: db_slot.clone(),
        async_db: AsyncDaemonDbSlot::from_inner(async_db_slot.clone()),
        db_path: Some(db_path.to_path_buf()),
        codex_controller: CodexControllerHandle::new_with_async_db(
            sender.clone(),
            db_slot.clone(),
            async_db_slot.clone(),
            false,
        ),
        agent_tui_manager: AgentTuiManagerHandle::new_with_async_db(
            sender,
            db_slot,
            async_db_slot,
            false,
        ),
    }
}

pub(super) fn test_websocket_state_with_sync_db_only(db_path: &Path) -> DaemonHttpState {
    let (sender, _) = broadcast::channel(8);
    let db_slot = Arc::new(OnceLock::new());
    let async_db_slot = Arc::new(OnceLock::new());
    assert!(
        db_slot
            .set(Arc::new(Mutex::new(
                crate::daemon::db::DaemonDb::open(db_path).expect("open sync daemon db"),
            )))
            .is_ok(),
        "install sync db"
    );

    let manifest: DaemonManifest = serde_json::from_value(serde_json::json!({
        "version": "20.6.0",
        "pid": 1,
        "endpoint": "http://127.0.0.1:0",
        "started_at": "2026-04-13T00:00:00Z",
        "token_path": "/tmp/token",
        "sandboxed": false,
        "host_bridge": {},
        "revision": 0,
        "updated_at": "",
        "binary_stamp": null,
    }))
    .expect("deserialize daemon manifest");

    DaemonHttpState {
        token: "token".into(),
        sender: sender.clone(),
        manifest,
        daemon_epoch: "epoch".into(),
        replay_buffer: Arc::new(Mutex::new(ReplayBuffer::new(8))),
        db: db_slot.clone(),
        async_db: AsyncDaemonDbSlot::from_inner(async_db_slot),
        db_path: Some(db_path.to_path_buf()),
        codex_controller: CodexControllerHandle::new(sender.clone(), db_slot.clone(), false),
        agent_tui_manager: AgentTuiManagerHandle::new(sender, db_slot, false),
    }
}

pub(super) fn init_git_project(project_dir: &Path) {
    fs::create_dir_all(project_dir).expect("create project dir");
    let status = Command::new("git")
        .arg("init")
        .arg("-q")
        .arg(project_dir)
        .status()
        .expect("git init");
    assert!(status.success(), "git init should succeed");
}

pub(super) async fn start_async_session(
    state: &DaemonHttpState,
    project_dir: &Path,
    session_id: &str,
) {
    let async_db = state.async_db.get().expect("async db");
    start_session_direct_async(
        &SessionStartRequest {
            title: format!("{session_id} title"),
            context: format!("{session_id} context"),
            runtime: "claude".into(),
            session_id: Some(session_id.to_string()),
            project_dir: project_dir.to_string_lossy().into_owned(),
        },
        async_db.as_ref(),
    )
    .await
    .expect("start session");
}

pub(super) async fn join_async_worker(
    state: &DaemonHttpState,
    session_id: &str,
    project_dir: &Path,
    name: &str,
) -> String {
    let async_db = state.async_db.get().expect("async db");
    let joined = join_session_direct_async(
        session_id,
        &SessionJoinRequest {
            runtime: "codex".into(),
            role: SessionRole::Worker,
            capabilities: vec!["general".into()],
            name: Some(name.to_string()),
            project_dir: project_dir.to_string_lossy().into_owned(),
            persona: None,
        },
        async_db.as_ref(),
    )
    .await
    .expect("join session");
    joined
        .agents
        .keys()
        .find(|agent_id| agent_id.starts_with("codex-"))
        .expect("worker id")
        .to_string()
}

pub(super) async fn leader_id_for_session(state: &DaemonHttpState, session_id: &str) -> String {
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
    project_dir: &Path,
    message: &str,
) -> String {
    let async_db = state.async_db.get().expect("async db");
    let resolved = async_db
        .resolve_session(session_id)
        .await
        .expect("resolve session")
        .expect("session present");
    std::fs::create_dir_all(project_dir).expect("create project dir");
    let agent = resolved
        .state
        .agents
        .get(agent_id)
        .expect("agent present")
        .clone();
    let runtime = runtime_for_name(&agent.runtime).expect("runtime");
    let signal = build_signal(
        actor_id,
        "inject_context",
        message,
        Some("task:websocket-signal"),
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

#[tokio::test]
async fn websocket_round_trip_smoke_covers_public_surface() {
    let mut replay_buffer = ReplayBuffer::new(4);
    let first_seq = replay_buffer.append("event-1".into());
    let second_seq = replay_buffer.append("event-2".into());
    assert_eq!(replay_buffer.current_seq(), 2);
    assert_eq!(
        replay_buffer.replay_since(first_seq),
        Some(vec![(second_seq, String::from("event-2"))])
    );

    let state = test_http_state_with_db();
    seed_sample_timeline(&state);
    let request = WsRequest {
        id: "req-smoke".into(),
        method: "session.timeline".into(),
        params: serde_json::json!({
            "session_id": "sess-test-1",
            "scope": "summary",
        }),
    };

    let response = dispatch_read_query(&request, &state).await;
    let frames = serialize_response_frames(&response).expect("serialize websocket response");
    assert_eq!(frames.len(), 1);

    let Message::Text(text) = &frames[0] else {
        panic!("expected inline websocket response frame");
    };
    let response: WsResponse = serde_json::from_str(text).expect("deserialize websocket response");
    assert_eq!(response.id, "req-smoke");
    assert!(response.error.is_none());
    assert_eq!(
        response
            .result
            .as_ref()
            .and_then(|result| result["revision"].as_i64()),
        Some(1)
    );
    assert_eq!(
        response
            .result
            .as_ref()
            .and_then(|result| result["entries"].as_array())
            .map(Vec::len),
        Some(1)
    );
    assert_eq!(
        response
            .result
            .as_ref()
            .and_then(|result| result["entries"].as_array())
            .and_then(|entries| entries.first())
            .and_then(|entry| entry["kind"].as_str()),
        Some("tool_result")
    );
}

#[tokio::test]
async fn websocket_async_detail_query_succeeds_without_sync_db() {
    let state = test_http_state_with_async_db_timeline().await;
    let request = WsRequest {
        id: "req-detail-async".into(),
        method: "session.detail".into(),
        params: serde_json::json!({ "session_id": "sess-test-1" }),
    };

    let response = dispatch_read_query(&request, &state).await;

    assert!(response.error.is_none());
    assert_eq!(
        response
            .result
            .as_ref()
            .and_then(|result| result["session"]["session_id"].as_str()),
        Some("sess-test-1")
    );
}

#[tokio::test]
async fn websocket_async_diagnostics_query_succeeds_without_sync_db() {
    let state = test_http_state_with_async_db_timeline().await;
    let request = WsRequest {
        id: "req-diagnostics-async".into(),
        method: "diagnostics".into(),
        params: serde_json::json!({}),
    };

    let response = dispatch_read_query(&request, &state).await;

    assert!(response.error.is_none());
    assert!(
        response
            .result
            .as_ref()
            .is_some_and(|result| result["recent_events"].is_array())
    );
}

#[tokio::test]
async fn session_subscribe_broadcasts_async_snapshot_without_sync_db() {
    let state = test_http_state_with_async_db_timeline().await;
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let mut receiver = state.sender.subscribe();
    let request = WsRequest {
        id: "req-session-subscribe".into(),
        method: "session.subscribe".into(),
        params: serde_json::json!({ "session_id": "sess-test-1" }),
    };

    let response = handle_session_subscribe(&request, &state, &connection).await;

    assert!(response.error.is_none());
    assert_eq!(
        receiver.recv().await.expect("sessions_updated").event,
        "sessions_updated"
    );
    assert_eq!(
        receiver.recv().await.expect("session_updated").event,
        "session_updated"
    );
    assert_eq!(
        receiver.recv().await.expect("session_extensions").event,
        "session_extensions"
    );
}

#[tokio::test]
async fn stream_subscribe_broadcasts_async_index_without_sync_db() {
    let state = test_http_state_with_async_db_timeline().await;
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let mut receiver = state.sender.subscribe();
    let request = WsRequest {
        id: "req-stream-subscribe".into(),
        method: "stream.subscribe".into(),
        params: serde_json::json!({}),
    };

    let response = handle_stream_subscribe(&request, &state, &connection).await;

    assert!(response.error.is_none());
    assert_eq!(
        receiver.recv().await.expect("sessions_updated").event,
        "sessions_updated"
    );
}

#[tokio::test]
async fn websocket_async_task_create_mutation_succeeds_without_sync_db() {
    let state = test_http_state_with_async_db_timeline().await;
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let request = WsRequest {
        id: "req-task-create-async".into(),
        method: "task.create".into(),
        params: serde_json::json!({
            "session_id": "sess-test-1",
            "actor": "spoofed-client",
            "title": "async websocket task",
            "context": "prefer sqlx websocket path",
            "severity": "high",
            "suggested_fix": "use async mutation dispatcher"
        }),
    };

    let response = dispatch(&request, &state, &connection).await;

    assert!(response.error.is_none());
    assert_eq!(
        response
            .result
            .as_ref()
            .and_then(|result| result["tasks"].as_array())
            .map(Vec::len),
        Some(1)
    );
    assert_eq!(
        response
            .result
            .as_ref()
            .and_then(|result| result["tasks"].as_array())
            .and_then(|tasks| tasks.first())
            .and_then(|task| task["title"].as_str()),
        Some("async websocket task")
    );
}

#[test]
fn websocket_async_signal_cancel_mutation_succeeds_without_sync_db() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("ws-async-signal-cancel-leader")),
                ("CODEX_SESSION_ID", Some("ws-async-signal-cancel-worker")),
            ],
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let project_dir = sandbox.path().join("project");
                    init_git_project(&project_dir);

                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_websocket_state_with_empty_async_db(&db_path).await;
                    start_async_session(&state, &project_dir, "ws-async-signal-cancel").await;
                    let worker_id = join_async_worker(
                        &state,
                        "ws-async-signal-cancel",
                        &project_dir,
                        "Async WS Signal Worker",
                    )
                    .await;
                    let leader_id = leader_id_for_session(&state, "ws-async-signal-cancel").await;
                    let signal_id = seed_pending_signal(
                        &state,
                        "ws-async-signal-cancel",
                        &leader_id,
                        &worker_id,
                        &project_dir,
                        "cancel from websocket",
                    )
                    .await;
                    let connection = Arc::new(Mutex::new(ConnectionState::new()));
                    let request = WsRequest {
                        id: "req-signal-cancel-async".into(),
                        method: "signal.cancel".into(),
                        params: serde_json::json!({
                            "session_id": "ws-async-signal-cancel",
                            "actor": "spoofed-client",
                            "agent_id": worker_id,
                            "signal_id": signal_id.clone()
                        }),
                    };

                    let response = dispatch(&request, &state, &connection).await;

                    assert!(response.error.is_none());
                    let async_db = state.async_db.get().expect("async db");
                    assert_eq!(
                        async_db
                            .load_signals("ws-async-signal-cancel")
                            .await
                            .expect("load signals")
                            .into_iter()
                            .find(|signal| signal.signal.signal_id == signal_id)
                            .map(|signal| signal.status),
                        Some(SessionSignalStatus::Rejected)
                    );
                });
            },
        );
    });
}
