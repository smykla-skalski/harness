use axum::extract::State;
use axum::http::StatusCode;
use serde_json::Value;

use super::*;
use crate::daemon::agent_tui::{
    AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus, TerminalScreenSnapshot,
};
use crate::daemon::http::agents::{get_agent_tui, get_agent_tuis};

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
