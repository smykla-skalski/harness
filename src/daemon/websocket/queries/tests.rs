use serde_json::Value;

use super::super::test_support::{
    seed_sample_agent_tui, seed_sample_codex_run, seed_sample_timeline,
    test_http_state_with_async_db_timeline, test_http_state_with_db,
};
use super::*;
use crate::daemon::protocol::WsRequest;

#[tokio::test]
async fn dispatch_read_query_runtime_session_resolve_requires_runtime_name() {
    let state = test_http_state_with_db();
    let request = WsRequest {
        id: "req-resolve-missing".into(),
        method: "runtime_session.resolve".into(),
        params: serde_json::json!({ "runtime_session_id": "sess-worker" }),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;

    assert_eq!(response.id, "req-resolve-missing");
    let error = response.error.expect("missing param error");
    assert_eq!(error.code, "MISSING_PARAM");
}

#[tokio::test]
async fn dispatch_read_query_runtime_session_resolve_returns_null_for_unknown_session() {
    let state = test_http_state_with_db();
    let request = WsRequest {
        id: "req-resolve-null".into(),
        method: "runtime_session.resolve".into(),
        params: serde_json::json!({
            "runtime_name": "codex",
            "runtime_session_id": "missing-runtime-session",
        }),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;

    assert_eq!(response.id, "req-resolve-null");
    assert!(response.error.is_none());
    let result = response.result.expect("resolve response");
    assert!(result.get("resolved").is_some_and(Value::is_null));
}

#[tokio::test]
async fn dispatch_read_query_health_succeeds_when_db_lock_is_held() {
    let state = test_http_state_with_db();
    let db = state.db.get().expect("db slot").clone();
    let _db_guard = db.lock().expect("db lock");
    let request = WsRequest {
        id: "req-1".into(),
        method: "health".into(),
        params: serde_json::json!({}),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;

    assert_eq!(response.id, "req-1");
    assert!(response.error.is_none());
    assert_eq!(
        response
            .result
            .expect("health response")
            .get("status")
            .and_then(Value::as_str),
        Some("ok")
    );
}

#[tokio::test]
async fn dispatch_read_query_session_managed_agents_returns_merged_response() {
    let state = test_http_state_with_db();
    seed_sample_agent_tui(&state, "tui-3", "2026-04-13T19:12:00Z");
    seed_sample_codex_run(&state, "run-1", "2026-04-13T19:13:00Z");
    let request = WsRequest {
        id: "req-managed-agents".into(),
        method: "session.managed_agents".into(),
        params: serde_json::json!({ "session_id": "sess-test-1" }),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;

    assert!(response.error.is_none());
    let result = response.result.expect("managed agent list response");
    let Value::Array(entries) = result["agents"].clone() else {
        panic!("expected managed agent list response to contain an agents array");
    };
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0]["kind"].as_str(), Some("codex"));
    assert_eq!(entries[0]["snapshot"]["run_id"].as_str(), Some("run-1"));
    assert_eq!(entries[1]["kind"].as_str(), Some("terminal"));
    assert_eq!(entries[1]["snapshot"]["tui_id"].as_str(), Some("tui-3"));
}

#[tokio::test]
async fn dispatch_read_query_managed_agent_detail_returns_coded_snapshot() {
    let state = test_http_state_with_db();
    seed_sample_codex_run(&state, "run-2", "2026-04-13T19:14:00Z");
    let request = WsRequest {
        id: "req-managed-agent".into(),
        method: "managed_agent.detail".into(),
        params: serde_json::json!({ "agent_id": "run-2" }),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;

    assert!(response.error.is_none());
    let result = response.result.expect("managed agent response");
    assert_eq!(result["kind"].as_str(), Some("codex"));
    assert_eq!(result["snapshot"]["run_id"].as_str(), Some("run-2"));
    assert_eq!(
        result["snapshot"]["session_id"].as_str(),
        Some("sess-test-1")
    );
}

#[tokio::test]
async fn dispatch_read_query_session_timeline_summary_scope_returns_window_metadata() {
    let state = test_http_state_with_db();
    seed_sample_timeline(&state);
    let request = WsRequest {
        id: "req-timeline-summary".into(),
        method: "session.timeline".into(),
        params: serde_json::json!({
            "session_id": "sess-test-1",
            "scope": "summary",
        }),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;

    assert!(response.error.is_none());
    let result = response.result.expect("timeline response");
    assert_eq!(result["revision"].as_i64(), Some(1));
    assert_eq!(result["total_count"].as_u64(), Some(1));
    assert_eq!(result["unchanged"].as_bool(), Some(false));
    let Value::Array(entries) = result["entries"].clone() else {
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

#[tokio::test]
async fn dispatch_read_query_session_timeline_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_timeline().await;
    let request = WsRequest {
        id: "req-timeline-async".into(),
        method: "session.timeline".into(),
        params: serde_json::json!({
            "session_id": "sess-test-1",
            "scope": "summary",
        }),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;

    assert!(response.error.is_none());
    let result = response.result.expect("timeline response");
    assert_eq!(result["revision"].as_i64(), Some(1));
    assert_eq!(result["total_count"].as_u64(), Some(1));
    let Value::Array(entries) = result["entries"].clone() else {
        panic!("expected timeline entries array response");
    };
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["payload"], serde_json::json!({}));
}
