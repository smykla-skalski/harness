use axum::extract::State;
use axum::http::StatusCode;
use serde_json::Value;

use super::*;
use crate::daemon::http::codex::{get_codex_run, get_codex_runs};
use crate::daemon::protocol::{CodexRunMode, CodexRunSnapshot, CodexRunStatus};

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
