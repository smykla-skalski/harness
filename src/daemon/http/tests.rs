use std::collections::BTreeMap;
use std::env::temp_dir;
use std::sync::{Arc, Mutex, OnceLock};

use axum::body::to_bytes;
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode, header::AUTHORIZATION};
use serde_json::Value;
use tokio::sync::broadcast;
use uuid::Uuid;

use crate::agents::runtime::RuntimeCapabilities;
use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};
use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::DaemonDb;
use crate::daemon::index::DiscoveredProject;
use crate::daemon::protocol::{ObserveSessionRequest, SessionEndRequest};
use crate::daemon::state::DaemonManifest;
use crate::errors::CliErrorKind;
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use crate::session::types::{
    AgentRegistration, AgentStatus, SessionMetrics, SessionRole, SessionState, SessionStatus,
};

use super::DaemonHttpState;
use super::agents::{post_remove_agent, post_role_change, post_transfer_leader};
use super::auth::authorize_control_request;
use super::core::{get_diagnostics, get_health, get_projects};
use super::response::{map_json, request_activity_log_level};
use super::sessions::{
    SessionScopeQuery, get_session, get_sessions, get_timeline, post_end_session,
    post_observe_session, post_session_join, post_session_start,
};
use super::signals::{post_cancel_signal, post_send_signal, post_signal_ack};
use super::tasks::{
    post_task_assign, post_task_checkpoint, post_task_create, post_task_drop,
    post_task_queue_policy, post_task_update,
};

mod async_agent_mutations;
mod async_lifecycle_mutations;
mod async_mutations;
mod async_observe;
mod async_reads;
mod async_signal_mutations;
mod async_stream;

async fn response_body(result: Result<Value, crate::errors::CliError>) -> (StatusCode, Value) {
    let response = map_json(result);
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 4096).await.expect("body");
    let json: Value = serde_json::from_slice(&bytes).expect("json body");
    (status, json)
}

pub(super) async fn response_json(response: axum::response::Response) -> (StatusCode, Value) {
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 4 * 1024 * 1024)
        .await
        .expect("body");
    let json: Value = serde_json::from_slice(&bytes).expect("json body");
    (status, json)
}

pub(super) fn auth_headers() -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(
        AUTHORIZATION,
        "Bearer token".parse().expect("authorization header"),
    );
    headers
}

fn test_http_state_with_db() -> DaemonHttpState {
    let (sender, _) = broadcast::channel(8);
    let db_slot = Arc::new(OnceLock::new());
    let db_path = temp_dir().join(format!("harness-http-test-{}.db", Uuid::new_v4()));
    let db = Arc::new(Mutex::new(DaemonDb::open(&db_path).expect("open file db")));
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
        async_db: super::AsyncDaemonDbSlot::empty(),
        db_path: Some(db_path),
        codex_controller: CodexControllerHandle::new(sender.clone(), db_slot.clone(), false),
        agent_tui_manager: AgentTuiManagerHandle::new(sender, db_slot, false),
    }
}

#[tokio::test]
async fn map_json_maps_codex_unavailable_to_503() {
    let error = CliErrorKind::codex_server_unavailable("ws://127.0.0.1:4500").into();
    let (status, body) = response_body(Err(error)).await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["error"], "codex-unavailable");
    assert_eq!(body["endpoint"], "ws://127.0.0.1:4500");
    assert_eq!(body["hint"], "run: harness bridge start");
}

#[test]
fn request_logging_uses_debug_activity_level() {
    assert_eq!(request_activity_log_level(), tracing::Level::DEBUG);
}

#[tokio::test]
async fn http_round_trip_smoke_covers_public_surface() {
    let state = test_http_state_with_db();
    let db = state.db.get().expect("db slot").clone();
    {
        let db = db.lock().expect("db lock");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        db.save_session_state(&project.project_id, &sample_session_state())
            .expect("save session state");
        db.sync_conversation_events(
            "sess-test-1",
            "codex-worker",
            "codex",
            &[sample_tool_result_event()],
        )
        .expect("sync conversation events");
    }

    let health = get_health(auth_headers(), State(state.clone())).await;
    assert_eq!(health.status(), StatusCode::OK);

    let diagnostics = get_diagnostics(auth_headers(), State(state.clone())).await;
    assert_eq!(diagnostics.status(), StatusCode::OK);

    let timeline = get_timeline(
        axum::extract::Path("sess-test-1".to_owned()),
        Query(SessionScopeQuery::with_scope("summary")),
        auth_headers(),
        State(state.clone()),
    )
    .await;
    let (timeline_status, timeline_body) = response_json(timeline).await;
    assert_eq!(timeline_status, StatusCode::OK);
    assert_eq!(timeline_body["revision"].as_i64(), Some(1));
    assert_eq!(timeline_body["total_count"].as_u64(), Some(1));

    let mut request = SessionEndRequest {
        actor: "spoofed-leader".into(),
    };
    authorize_control_request(&auth_headers(), &state, &mut request).expect("authorize request");
    assert_eq!(request.actor, CONTROL_PLANE_ACTOR_ID);

    let (conflict_status, conflict_body) = response_body(Err(
        CliErrorKind::session_agent_conflict("agent-tui still active").into(),
    ))
    .await;
    assert_eq!(conflict_status, StatusCode::CONFLICT);
    assert_eq!(conflict_body["error"]["code"], "KSRCLI092");
    assert_eq!(request_activity_log_level(), tracing::Level::DEBUG);
}

#[tokio::test]
async fn map_json_maps_sandbox_disabled_to_501() {
    let error = CliErrorKind::sandbox_feature_disabled("codex.stdio").into();
    let (status, body) = response_body(Err(error)).await;

    assert_eq!(status, StatusCode::NOT_IMPLEMENTED);
    assert_eq!(body["error"], "sandbox-disabled");
    assert_eq!(body["feature"], "codex.stdio");
}

#[tokio::test]
async fn map_json_maps_other_errors_to_400() {
    let error = CliErrorKind::workflow_parse("bad request").into();
    let (status, body) = response_body(Err(error)).await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"]["code"].as_str().is_some());
}

#[tokio::test]
async fn map_json_maps_session_agent_conflict_to_409() {
    let error = CliErrorKind::session_agent_conflict("agent-tui still active").into();
    let (status, body) = response_body(Err(error)).await;

    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(body["error"]["code"], "KSRCLI092");
}

#[tokio::test]
async fn get_health_requires_auth() {
    let response = get_health(HeaderMap::new(), State(test_http_state_with_db())).await;

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn get_health_responds_when_db_lock_is_held() {
    let state = test_http_state_with_db();
    let db = state.db.get().expect("db slot").clone();
    let _db_guard = db.lock().expect("db lock");

    let response = get_health(auth_headers(), State(state)).await;

    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn get_diagnostics_responds_when_db_lock_is_held() {
    let state = test_http_state_with_db();
    let db = state.db.get().expect("db slot").clone();
    let _db_guard = db.lock().expect("db lock");

    let response = get_diagnostics(auth_headers(), State(state)).await;

    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn get_timeline_summary_scope_returns_window_metadata() {
    let state = test_http_state_with_db();
    let db = state.db.get().expect("db slot").clone();
    {
        let db = db.lock().expect("db lock");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        db.save_session_state(&project.project_id, &sample_session_state())
            .expect("save session state");
        db.sync_conversation_events(
            "sess-test-1",
            "codex-worker",
            "codex",
            &[sample_tool_result_event()],
        )
        .expect("sync conversation events");
    }

    let response = get_timeline(
        axum::extract::Path("sess-test-1".to_owned()),
        Query(SessionScopeQuery::with_scope("summary")),
        auth_headers(),
        State(state),
    )
    .await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["revision"].as_i64(), Some(1));
    assert_eq!(body["total_count"].as_u64(), Some(1));
    assert_eq!(body["unchanged"].as_bool(), Some(false));
    let Value::Array(entries) = body["entries"].clone() else {
        panic!("expected timeline entries array response");
    };
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["kind"].as_str(), Some("tool_result"));
    assert_eq!(
        entries[0]["summary"].as_str(),
        Some("codex-worker received a result from Bash")
    );
    assert_eq!(entries[0]["payload"], serde_json::json!({}));
}

#[test]
fn authorize_control_request_rebinds_client_actor() {
    let state = test_http_state_with_db();
    let mut request = SessionEndRequest {
        actor: "spoofed-leader".into(),
    };

    authorize_control_request(&auth_headers(), &state, &mut request).expect("authorize request");

    assert_eq!(request.actor, CONTROL_PLANE_ACTOR_ID);
}

pub(super) fn sample_project() -> DiscoveredProject {
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

pub(super) fn sample_session_state() -> SessionState {
    let mut agents = BTreeMap::new();
    agents.insert(
        "codex-worker".into(),
        AgentRegistration {
            agent_id: "codex-worker".into(),
            name: "Codex Worker".into(),
            runtime: "codex".into(),
            role: SessionRole::Worker,
            capabilities: vec!["general".into()],
            joined_at: "2026-04-13T19:00:00Z".into(),
            updated_at: "2026-04-13T19:00:00Z".into(),
            status: AgentStatus::Active,
            agent_session_id: None,
            last_activity_at: Some("2026-04-13T19:00:00Z".into()),
            current_task_id: None,
            runtime_capabilities: RuntimeCapabilities::default(),
            persona: None,
        },
    );

    SessionState {
        schema_version: 3,
        state_version: 1,
        session_id: "sess-test-1".into(),
        title: "sess-test-1".into(),
        context: "http timeline scope fixture".into(),
        status: SessionStatus::Active,
        created_at: "2026-04-13T19:00:00Z".into(),
        updated_at: "2026-04-13T19:00:00Z".into(),
        agents,
        tasks: BTreeMap::new(),
        leader_id: None,
        archived_at: None,
        last_activity_at: Some("2026-04-13T19:00:00Z".into()),
        observe_id: None,
        pending_leader_transfer: None,
        metrics: SessionMetrics::default(),
    }
}

pub(super) fn sample_tool_result_event() -> ConversationEvent {
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
