use axum::extract::State;
use axum::http::StatusCode;
use serde_json::Value;

use super::*;
use crate::daemon::agent_tui::{
    AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus, TerminalScreenSnapshot,
};
use crate::daemon::http::managed_agents::{get_managed_agent, get_managed_agents};
use crate::daemon::protocol::{CodexRunMode, CodexRunSnapshot, CodexRunStatus};

#[tokio::test]
async fn get_managed_agents_merges_terminal_and_codex_snapshots_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;
    let async_db = state.async_db.get().expect("async db");
    async_db
        .save_codex_run(&CodexRunSnapshot {
            run_id: "codex-run-3".into(),
            session_id: "sess-test-1".into(),
            project_dir: "/tmp/harness".into(),
            thread_id: Some("thread-3".into()),
            turn_id: Some("turn-3".into()),
            mode: CodexRunMode::Report,
            status: CodexRunStatus::Running,
            prompt: "Investigate".into(),
            latest_summary: Some("Running".into()),
            final_message: None,
            error: None,
            pending_approvals: Vec::new(),
            created_at: "2026-04-14T14:00:00Z".into(),
            updated_at: "2026-04-14T14:01:00Z".into(),
            model: None,
        })
        .await
        .expect("seed codex run");
    async_db
        .save_agent_tui(&AgentTuiSnapshot {
            tui_id: "agent-tui-3".into(),
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
            created_at: "2026-04-14T15:00:00Z".into(),
            updated_at: "2026-04-14T15:01:00Z".into(),
        })
        .await
        .expect("seed agent tui");

    let response = get_managed_agents(
        axum::extract::Path("sess-test-1".to_owned()),
        auth_headers(),
        State(state),
    )
    .await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    let Value::Array(agents) = body["agents"].clone() else {
        panic!("expected managed agent list response");
    };
    assert_eq!(agents.len(), 2);
    assert_eq!(agents[0]["kind"].as_str(), Some("terminal"));
    assert_eq!(
        agents[0]["snapshot"]["tui_id"].as_str(),
        Some("agent-tui-3")
    );
    assert_eq!(agents[1]["kind"].as_str(), Some("codex"));
    assert_eq!(
        agents[1]["snapshot"]["run_id"].as_str(),
        Some("codex-run-3")
    );
}

#[tokio::test]
async fn get_managed_agent_wraps_codex_run_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;
    let async_db = state.async_db.get().expect("async db");
    async_db
        .save_codex_run(&CodexRunSnapshot {
            run_id: "codex-run-4".into(),
            session_id: "sess-test-1".into(),
            project_dir: "/tmp/harness".into(),
            thread_id: Some("thread-4".into()),
            turn_id: Some("turn-4".into()),
            mode: CodexRunMode::WorkspaceWrite,
            status: CodexRunStatus::Completed,
            prompt: "Patch it".into(),
            latest_summary: Some("Done".into()),
            final_message: Some("Finished".into()),
            error: None,
            pending_approvals: Vec::new(),
            created_at: "2026-04-14T16:00:00Z".into(),
            updated_at: "2026-04-14T16:01:00Z".into(),
            model: None,
        })
        .await
        .expect("seed codex run");

    let response = get_managed_agent(
        axum::extract::Path("codex-run-4".to_owned()),
        auth_headers(),
        State(state),
    )
    .await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["kind"].as_str(), Some("codex"));
    assert_eq!(body["snapshot"]["run_id"].as_str(), Some("codex-run-4"));
    assert_eq!(body["snapshot"]["status"].as_str(), Some("completed"));
}

#[tokio::test]
async fn get_managed_agents_uses_async_db_when_sync_db_is_unavailable_for_terminal_agents() {
    let state = test_http_state_with_async_db_only().await;
    let async_db = state.async_db.get().expect("async db");
    async_db
        .save_agent_tui(&AgentTuiSnapshot {
            tui_id: "agent-tui-5".into(),
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
                text: "running".into(),
            },
            transcript_path: "/tmp/harness/output.raw".into(),
            exit_code: None,
            signal: None,
            error: None,
            created_at: "2026-04-14T17:00:00Z".into(),
            updated_at: "2026-04-14T17:01:00Z".into(),
        })
        .await
        .expect("seed agent tui");

    let response = get_managed_agents(
        axum::extract::Path("sess-test-1".to_owned()),
        auth_headers(),
        State(state),
    )
    .await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    let Value::Array(agents) = body["agents"].clone() else {
        panic!("expected managed agent list response");
    };
    assert_eq!(agents.len(), 1);
    assert_eq!(agents[0]["kind"].as_str(), Some("terminal"));
    assert_eq!(
        agents[0]["snapshot"]["tui_id"].as_str(),
        Some("agent-tui-5")
    );
}

#[tokio::test]
async fn get_managed_agent_wraps_terminal_tui_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;
    let async_db = state.async_db.get().expect("async db");
    async_db
        .save_agent_tui(&AgentTuiSnapshot {
            tui_id: "agent-tui-6".into(),
            session_id: "sess-test-1".into(),
            agent_id: "codex-worker".into(),
            runtime: "codex".into(),
            status: AgentTuiStatus::Stopped,
            argv: vec!["codex".into()],
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
            created_at: "2026-04-14T18:00:00Z".into(),
            updated_at: "2026-04-14T18:01:00Z".into(),
        })
        .await
        .expect("seed agent tui");

    let response = get_managed_agent(
        axum::extract::Path("agent-tui-6".to_owned()),
        auth_headers(),
        State(state),
    )
    .await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["kind"].as_str(), Some("terminal"));
    assert_eq!(body["snapshot"]["tui_id"].as_str(), Some("agent-tui-6"));
    assert_eq!(body["snapshot"]["status"].as_str(), Some("stopped"));
}
