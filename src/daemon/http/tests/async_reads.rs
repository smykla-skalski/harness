use std::env::temp_dir;
use std::sync::{Arc, Mutex, OnceLock};

use axum::extract::{Query, State};
use axum::http::StatusCode;
use serde_json::Value;
use tokio::sync::broadcast;
use uuid::Uuid;

use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::state::DaemonManifest;

use super::*;

pub(super) async fn test_http_state_with_async_db_only() -> DaemonHttpState {
    let (sender, _) = broadcast::channel(8);
    let db_slot = Arc::new(OnceLock::new());
    let async_db_slot = Arc::new(OnceLock::new());
    let db_path = temp_dir().join(format!("harness-http-test-async-{}.db", Uuid::new_v4()));
    let db = DaemonDb::open(&db_path).expect("open file db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    db.save_session_state(&project.project_id, &sample_session_state())
        .expect("save session state");
    drop(db);

    assert!(
        async_db_slot
            .set(Arc::new(
                AsyncDaemonDb::connect(&db_path)
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
        replay_buffer: Arc::new(Mutex::new(crate::daemon::websocket::ReplayBuffer::new(8))),
        db: db_slot.clone(),
        async_db: super::super::AsyncDaemonDbSlot::from_inner(async_db_slot),
        db_path: Some(db_path),
        codex_controller: CodexControllerHandle::new(sender.clone(), db_slot.clone(), false),
        agent_tui_manager: AgentTuiManagerHandle::new(sender, db_slot, false),
    }
}

pub(super) async fn test_http_state_with_async_db_timeline_only() -> DaemonHttpState {
    let (sender, _) = broadcast::channel(8);
    let db_slot = Arc::new(OnceLock::new());
    let async_db_slot = Arc::new(OnceLock::new());
    let db_path = temp_dir().join(format!("harness-http-test-async-{}.db", Uuid::new_v4()));
    let db = DaemonDb::open(&db_path).expect("open file db");
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
    drop(db);

    assert!(
        async_db_slot
            .set(Arc::new(
                AsyncDaemonDb::connect(&db_path)
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
        replay_buffer: Arc::new(Mutex::new(crate::daemon::websocket::ReplayBuffer::new(8))),
        db: db_slot.clone(),
        async_db: super::super::AsyncDaemonDbSlot::from_inner(async_db_slot),
        db_path: Some(db_path),
        codex_controller: CodexControllerHandle::new(sender.clone(), db_slot.clone(), false),
        agent_tui_manager: AgentTuiManagerHandle::new(sender, db_slot, false),
    }
}

#[tokio::test]
async fn get_projects_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;

    let response = get_projects(auth_headers(), State(state)).await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    let Value::Array(projects) = body else {
        panic!("expected project summary array response");
    };
    assert_eq!(projects.len(), 1);
    assert_eq!(projects[0]["name"].as_str(), Some("harness"));
    assert_eq!(projects[0]["total_session_count"].as_u64(), Some(1));
}

#[tokio::test]
async fn get_sessions_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;

    let response = get_sessions(auth_headers(), State(state)).await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    let Value::Array(sessions) = body else {
        panic!("expected session summary array response");
    };
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["session_id"].as_str(), Some("sess-test-1"));
}

#[tokio::test]
async fn get_session_core_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;

    let response = get_session(
        axum::extract::Path("sess-test-1".to_owned()),
        Query(SessionScopeQuery::with_scope("core")),
        auth_headers(),
        State(state),
    )
    .await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["session"]["session_id"].as_str(), Some("sess-test-1"));
    let Value::Array(agents) = body["agents"].clone() else {
        panic!("expected agent array response");
    };
    assert_eq!(agents.len(), 1);
}

#[tokio::test]
async fn get_session_full_detail_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;

    let response = get_session(
        axum::extract::Path("sess-test-1".to_owned()),
        Query(SessionScopeQuery::default()),
        auth_headers(),
        State(state),
    )
    .await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["session"]["session_id"].as_str(), Some("sess-test-1"));
}

#[tokio::test]
async fn get_diagnostics_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;

    let response = get_diagnostics(auth_headers(), State(state)).await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["recent_events"].is_array());
}

#[tokio::test]
async fn get_timeline_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_timeline_only().await;

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
    let Value::Array(entries) = body["entries"].clone() else {
        panic!("expected timeline entries array response");
    };
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["payload"], serde_json::json!({}));
}
