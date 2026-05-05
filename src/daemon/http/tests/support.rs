use std::collections::BTreeMap;
use std::env::temp_dir;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use axum::body::to_bytes;
use axum::http::{HeaderMap, StatusCode, header::AUTHORIZATION};
use serde_json::Value;
use tokio::sync::broadcast;
use uuid::Uuid;

use crate::agents::runtime::RuntimeCapabilities;
use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};
use crate::daemon::agent_acp::AcpAgentManagerHandle;
use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::DaemonDb;
use crate::daemon::index::DiscoveredProject;
use crate::daemon::state::DaemonManifest;
use crate::session::types::{
    AgentRegistration, AgentStatus, SessionMetrics, SessionRole, SessionState, SessionStatus,
};

use super::DaemonHttpState;
use super::super::response::map_json;

pub(in crate::daemon::http) async fn response_body(
    result: Result<Value, crate::errors::CliError>,
) -> (StatusCode, Value) {
    let response = map_json(result);
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 4096).await.expect("body");
    let json: Value = serde_json::from_slice(&bytes).expect("json body");
    (status, json)
}

pub(in crate::daemon::http) async fn response_json(
    response: axum::response::Response,
) -> (StatusCode, Value) {
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 4 * 1024 * 1024)
        .await
        .expect("body");
    let json: Value = serde_json::from_slice(&bytes).expect("json body");
    (status, json)
}

pub(in crate::daemon::http) fn auth_headers() -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(
        AUTHORIZATION,
        "Bearer token".parse().expect("authorization header"),
    );
    headers
}

pub(in crate::daemon::http) fn test_http_state_with_db() -> DaemonHttpState {
    let (sender, _) = broadcast::channel(8);
    let db_slot = Arc::new(OnceLock::new());
    let async_db = Arc::new(OnceLock::new());
    let db_path = temp_dir().join(format!("harness-http-test-{}.db", Uuid::new_v4()));
    let db = Arc::new(Mutex::new(DaemonDb::open(&db_path).expect("open file db")));
    db_slot.set(db).expect("install db");
    async_db
        .set(super::super::connect_async_db_for_tests(&db_path))
        .expect("install async db");
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
        replay_buffer: Arc::new(Mutex::new(crate::daemon::websocket::ReplayBuffer::new(8))),
        db: db_slot.clone(),
        async_db: super::super::AsyncDaemonDbSlot::from_inner(async_db.clone()),
        db_path: Some(db_path),
        codex_controller: CodexControllerHandle::new_with_async_db(
            sender.clone(),
            db_slot.clone(),
            async_db.clone(),
            false,
        ),
        acp_agent_manager: AcpAgentManagerHandle::new_with_async_db(
            sender.clone(),
            db_slot.clone(),
            async_db.clone(),
        ),
        agent_tui_manager: AgentTuiManagerHandle::new_with_async_db(
            sender, db_slot, async_db, false,
        ),
        managed_agent_mutation_locks: super::super::ManagedAgentMutationLocks::default(),
    }
}

pub(in crate::daemon::http) fn test_http_state_with_sync_db_only(
    db_path: &std::path::Path,
) -> DaemonHttpState {
    let (sender, _) = broadcast::channel(8);
    let db_slot = Arc::new(OnceLock::new());
    let async_db = Arc::new(OnceLock::new());
    let db = Arc::new(Mutex::new(DaemonDb::open(db_path).expect("open file db")));
    db_slot.set(db).expect("install db");
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
        replay_buffer: Arc::new(Mutex::new(crate::daemon::websocket::ReplayBuffer::new(8))),
        db: db_slot.clone(),
        async_db: super::super::AsyncDaemonDbSlot::from_inner(async_db),
        db_path: Some(db_path.to_path_buf()),
        codex_controller: CodexControllerHandle::new(sender.clone(), db_slot.clone(), false),
        acp_agent_manager: AcpAgentManagerHandle::new(sender.clone(), db_slot.clone()),
        agent_tui_manager: AgentTuiManagerHandle::new(sender, db_slot, false),
        managed_agent_mutation_locks: super::super::ManagedAgentMutationLocks::default(),
    }
}

pub(in crate::daemon::http) fn sample_project() -> DiscoveredProject {
    DiscoveredProject {
        project_id: "project-abc123".into(),
        name: "harness".into(),
        project_dir: Some("/tmp/harness".into()),
        repository_root: Some("/tmp/harness".into()),
        checkout_id: "checkout-abc123".into(),
        checkout_name: "Repository".into(),
        context_root: "/tmp/data/projects/project-abc123".into(),
        is_worktree: false,
        worktree_name: None,
    }
}

pub(in crate::daemon::http) fn sample_session_state() -> SessionState {
    let now = chrono::Utc::now().to_rfc3339();
    let mut agents = BTreeMap::new();
    agents.insert(
        "codex-worker".into(),
        AgentRegistration {
            agent_id: "codex-worker".into(),
            name: "Codex Worker".into(),
            runtime: "codex".into(),
            role: SessionRole::Worker,
            capabilities: vec!["general".into()],
            joined_at: now.clone(),
            updated_at: now.clone(),
            status: AgentStatus::Active,
            agent_session_id: None,
            managed_agent: None,
            last_activity_at: Some(now.clone()),
            current_task_id: None,
            runtime_capabilities: RuntimeCapabilities::default(),
            persona: None,
        },
    );

    SessionState {
        schema_version: 3,
        state_version: 1,
        session_id: "sess-test-1".into(),
        project_name: String::new(),
        worktree_path: PathBuf::new(),
        shared_path: PathBuf::new(),
        origin_path: PathBuf::new(),
        branch_ref: String::new(),
        title: "sess-test-1".into(),
        context: "http timeline scope fixture".into(),
        status: SessionStatus::Active,
        policy: Default::default(),
        created_at: now.clone(),
        updated_at: now.clone(),
        agents,
        tasks: BTreeMap::new(),
        leader_id: None,
        archived_at: None,
        last_activity_at: Some(now),
        observe_id: None,
        pending_leader_transfer: None,
        external_origin: None,
        adopted_at: None,
        metrics: SessionMetrics::default(),
    }
}

pub(in crate::daemon::http) fn sample_tool_result_event() -> ConversationEvent {
    ConversationEvent {
        timestamp: Some("2026-04-13T19:02:00Z".into()),
        sequence: 1,
        kind: ConversationEventKind::ToolResult {
            tool_name: "Bash".into(),
            invocation_id: Some("call-bash-1".into()),
            output: serde_json::json!({
                "stdout": "x".repeat(8_192),
                "exit_code": 0,
            }),
            is_error: false,
            duration_ms: Some(125),
        },
        agent: "codex-worker".into(),
        session_id: "sess-test-1".into(),
    }
}
