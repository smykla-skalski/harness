use std::env::temp_dir;
use std::sync::{Arc, Mutex, OnceLock};

use axum::extract::{Query, State};
use axum::http::StatusCode;
use serde_json::Value;
use tokio::sync::broadcast;
use uuid::Uuid;

use crate::daemon::agent_tui::{
    AgentTuiManagerHandle, AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus, TerminalScreenSnapshot,
};
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::protocol::{CodexRunMode, CodexRunSnapshot, CodexRunStatus};
use crate::daemon::state::DaemonManifest;

use super::super::agents::{get_agent_tui, get_agent_tuis};
use super::super::codex::{get_codex_run, get_codex_runs};
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
        async_db: super::super::AsyncDaemonDbSlot::from_inner(async_db_slot.clone()),
        db_path: Some(db_path),
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
        async_db: super::super::AsyncDaemonDbSlot::from_inner(async_db_slot.clone()),
        db_path: Some(db_path),
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

#[tokio::test]
async fn get_codex_runs_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;
    let async_db = state.async_db.get().expect("async db");
    async_db
        .save_codex_run(&CodexRunSnapshot {
            run_id: "codex-run-1".into(),
            session_id: "sess-test-1".into(),
            project_dir: "/tmp/harness".into(),
            thread_id: Some("thread-1".into()),
            turn_id: Some("turn-1".into()),
            mode: CodexRunMode::Report,
            status: CodexRunStatus::Running,
            prompt: "Summarize the issue".into(),
            latest_summary: Some("Working".into()),
            final_message: None,
            error: None,
            pending_approvals: Vec::new(),
            created_at: "2026-04-14T10:00:00Z".into(),
            updated_at: "2026-04-14T10:01:00Z".into(),
        })
        .await
        .expect("seed codex run");

    let response = get_codex_runs(
        axum::extract::Path("sess-test-1".to_owned()),
        auth_headers(),
        State(state),
    )
    .await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    let Value::Array(runs) = body["runs"].clone() else {
        panic!("expected codex run list response");
    };
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0]["run_id"].as_str(), Some("codex-run-1"));
}

#[tokio::test]
async fn get_codex_run_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;
    let async_db = state.async_db.get().expect("async db");
    async_db
        .save_codex_run(&CodexRunSnapshot {
            run_id: "codex-run-2".into(),
            session_id: "sess-test-1".into(),
            project_dir: "/tmp/harness".into(),
            thread_id: Some("thread-2".into()),
            turn_id: Some("turn-2".into()),
            mode: CodexRunMode::WorkspaceWrite,
            status: CodexRunStatus::Completed,
            prompt: "Fix the bug".into(),
            latest_summary: Some("Done".into()),
            final_message: Some("Finished".into()),
            error: None,
            pending_approvals: Vec::new(),
            created_at: "2026-04-14T11:00:00Z".into(),
            updated_at: "2026-04-14T11:01:00Z".into(),
        })
        .await
        .expect("seed codex run");

    let response = get_codex_run(
        axum::extract::Path("codex-run-2".to_owned()),
        auth_headers(),
        State(state),
    )
    .await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["run_id"].as_str(), Some("codex-run-2"));
    assert_eq!(body["status"].as_str(), Some("completed"));
}

#[tokio::test]
async fn get_agent_tuis_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;
    let async_db = state.async_db.get().expect("async db");
    async_db
        .save_agent_tui(&AgentTuiSnapshot {
            tui_id: "agent-tui-1".into(),
            session_id: "sess-test-1".into(),
            agent_id: "codex-worker".into(),
            runtime: "codex".into(),
            status: AgentTuiStatus::Running,
            argv: vec!["codex".into()],
            project_dir: "/tmp/harness".into(),
            size: AgentTuiSize { rows: 24, cols: 80 },
            screen: TerminalScreenSnapshot {
                rows: 24,
                cols: 80,
                cursor_row: 0,
                cursor_col: 0,
                text: "ready".into(),
            },
            transcript_path: "/tmp/harness/output.raw".into(),
            exit_code: None,
            signal: None,
            error: None,
            created_at: "2026-04-14T12:00:00Z".into(),
            updated_at: "2026-04-14T12:01:00Z".into(),
        })
        .await
        .expect("seed agent tui");

    let response = get_agent_tuis(
        axum::extract::Path("sess-test-1".to_owned()),
        auth_headers(),
        State(state),
    )
    .await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    let Value::Array(tuis) = body["tuis"].clone() else {
        panic!("expected agent tui list response");
    };
    assert_eq!(tuis.len(), 1);
    assert_eq!(tuis[0]["tui_id"].as_str(), Some("agent-tui-1"));
}

#[tokio::test]
async fn get_agent_tui_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;
    let async_db = state.async_db.get().expect("async db");
    async_db
        .save_agent_tui(&AgentTuiSnapshot {
            tui_id: "agent-tui-2".into(),
            session_id: "sess-test-1".into(),
            agent_id: "codex-worker".into(),
            runtime: "codex".into(),
            status: AgentTuiStatus::Stopped,
            argv: vec!["codex".into(), "--model".into(), "gpt-5.4".into()],
            project_dir: "/tmp/harness".into(),
            size: AgentTuiSize {
                rows: 30,
                cols: 120,
            },
            screen: TerminalScreenSnapshot {
                rows: 30,
                cols: 120,
                cursor_row: 1,
                cursor_col: 5,
                text: "done".into(),
            },
            transcript_path: "/tmp/harness/output.raw".into(),
            exit_code: Some(0),
            signal: None,
            error: None,
            created_at: "2026-04-14T13:00:00Z".into(),
            updated_at: "2026-04-14T13:01:00Z".into(),
        })
        .await
        .expect("seed agent tui");

    let response = get_agent_tui(
        axum::extract::Path("agent-tui-2".to_owned()),
        auth_headers(),
        State(state),
    )
    .await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["tui_id"].as_str(), Some("agent-tui-2"));
    assert_eq!(body["status"].as_str(), Some("stopped"));
}
