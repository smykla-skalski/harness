use axum::extract::ws::Message;
use std::path::Path;
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
use crate::daemon::agent_acp::AcpAgentManagerHandle;
use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::http::{AsyncDaemonDbSlot, DaemonHttpState};
use crate::daemon::protocol::{
    SessionJoinRequest, SessionStartRequest, WsRequest, WsResponse, mapped_ws_methods, ws_methods,
};
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
        acp_agent_manager: AcpAgentManagerHandle::new(sender.clone(), db_slot.clone()),
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
        acp_agent_manager: AcpAgentManagerHandle::new(sender.clone(), db_slot.clone()),
        agent_tui_manager: AgentTuiManagerHandle::new(sender, db_slot, false),
    }
}

pub(super) fn init_git_project(project_dir: &Path) {
    harness_testkit::init_git_repo_with_seed(project_dir);
}

pub(super) async fn start_async_session(
    state: &DaemonHttpState,
    project_dir: &Path,
    session_id: &str,
) {
    let async_db = state.async_db.get().expect("async db");
    let started = start_session_direct_async(
        &SessionStartRequest {
            title: format!("{session_id} title"),
            context: format!("{session_id} context"),
            session_id: Some(session_id.to_string()),
            project_dir: project_dir.to_string_lossy().into_owned(),
            policy_preset: None,
            base_ref: None,
        },
        async_db.as_ref(),
    )
    .await
    .expect("start session");

    join_session_direct_async(
        &started.session_id,
        &SessionJoinRequest {
            runtime: "claude".into(),
            role: SessionRole::Leader,
            fallback_role: None,
            capabilities: vec![],
            name: Some("leader".into()),
            project_dir: project_dir.to_string_lossy().into_owned(),
            persona: None,
        },
        async_db.as_ref(),
    )
    .await
    .expect("join leader");
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
            fallback_role: None,
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
    let runtime = runtime_for_name(agent.runtime.runtime_name()).expect("runtime");
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

mod public_surface;
