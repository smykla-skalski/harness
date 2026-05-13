use serde_json::Value;

use super::super::test_support::{
    seed_sample_agent_tui, seed_sample_codex_run, seed_sample_timeline,
    test_http_state_with_async_db_timeline, test_http_state_with_db,
};
use super::*;
use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};
use crate::daemon::db::DaemonDb;
use crate::daemon::http::DaemonHttpState;
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
        params: serde_json::json!({ "session_id": "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4" }),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;

    assert!(response.error.is_none());
    let result = response.result.expect("managed agent list response");
    let Value::Array(entries) = result["agents"].clone() else {
        panic!("expected managed agent list response to contain an agents array");
    };
    assert_eq!(entries.len(), 2);
    let codex = entries
        .iter()
        .find(|entry| entry["kind"].as_str() == Some("codex"))
        .expect("codex managed agent entry");
    assert_eq!(codex["snapshot"]["run_id"].as_str(), Some("run-1"));
    let terminal = entries
        .iter()
        .find(|entry| entry["kind"].as_str() == Some("terminal"))
        .expect("terminal managed agent entry");
    assert_eq!(terminal["snapshot"]["tui_id"].as_str(), Some("tui-3"));
}

#[tokio::test]
async fn dispatch_read_query_managed_agent_detail_returns_coded_snapshot() {
    let state = test_http_state_with_db();
    seed_sample_codex_run(&state, "run-2", "2026-04-13T19:14:00Z");
    let request = WsRequest {
        id: "req-managed-agent".into(),
        method: "managed_agent.detail".into(),
        params: serde_json::json!({ "managed_agent_id": "run-2" }),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;

    assert!(response.error.is_none());
    let result = response.result.expect("managed agent response");
    assert_eq!(result["kind"].as_str(), Some("codex"));
    assert_eq!(result["snapshot"]["run_id"].as_str(), Some("run-2"));
    assert_eq!(
        result["snapshot"]["session_id"].as_str(),
        Some("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4")
    );
}

#[tokio::test]
async fn dispatch_read_query_managed_agent_codex_transcript_returns_history() {
    let state = test_http_state_with_db();
    seed_sample_codex_run(&state, "run-3", "2026-04-13T19:15:00Z");
    let request = WsRequest {
        id: "req-codex-transcript".into(),
        method: "managed_agent.codex_transcript".into(),
        params: serde_json::json!({
            "session_id": "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
        }),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;

    assert_eq!(response.id, "req-codex-transcript");
    assert!(response.error.is_none());
    let result = response.result.expect("Codex transcript response");
    let Value::Array(entries) = result["entries"].clone() else {
        panic!("expected Codex transcript entries array");
    };
    assert_eq!(entries.len(), 2);
    let prompt_entry = entries
        .iter()
        .find(|entry| entry["kind"].as_str() == Some("user_prompt"))
        .expect("prompt entry");
    assert_eq!(
        prompt_entry["session_id"].as_str(),
        Some("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4")
    );
    assert_eq!(prompt_entry["agent_id"].as_str(), Some("codex-worker"));
    assert_eq!(prompt_entry["summary"].as_str(), Some("Investigate run-3"));
    assert_eq!(prompt_entry["payload"]["runtime"].as_str(), Some("codex"));
    assert_eq!(
        prompt_entry["payload"]["event"]["type"].as_str(),
        Some("user_prompt")
    );
    assert!(
        entries
            .iter()
            .all(|entry| entry["payload"]["event"]["delta"].as_bool() != Some(true)),
        "transcript should not emit one row per agent-message delta"
    );
}

#[tokio::test]
async fn dispatch_read_query_managed_agent_detail_rejects_session_agent_id_alias() {
    let state = test_http_state_with_db();
    let request = WsRequest {
        id: "req-managed-agent-wrong-id".into(),
        method: "managed_agent.detail".into(),
        params: serde_json::json!({ "session_agent_id": "worker-1" }),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;

    assert_eq!(response.id, "req-managed-agent-wrong-id");
    let error = response.error.expect("missing param error");
    assert_eq!(error.code, "MISSING_PARAM");
}

#[tokio::test]
async fn dispatch_read_query_managed_agent_detail_rejects_legacy_agent_id_param() {
    let state = test_http_state_with_db();
    let request = WsRequest {
        id: "req-managed-agent-legacy-id".into(),
        method: "managed_agent.detail".into(),
        params: serde_json::json!({ "agent_id": "run-2" }),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;

    assert_eq!(response.id, "req-managed-agent-legacy-id");
    let error = response.error.expect("missing param error");
    assert_eq!(error.code, "MISSING_PARAM");
    assert_eq!(error.message, "missing managed_agent_id");
}

#[tokio::test]
async fn dispatch_read_query_managed_agent_acp_inspect_returns_acp_disabled_when_feature_flag_off()
{
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("0"))], async {
        let state = test_http_state_with_db();
        let request = WsRequest {
            id: "req-acp-inspect-disabled".into(),
            method: "managed_agent.acp_inspect".into(),
            params: serde_json::json!({}),
            trace_context: None,
        };

        let response = dispatch_read_query(&request, &state).await;

        let error = response.error.expect("ACP disabled error");
        assert_eq!(error.code, "ACP_DISABLED");
    })
    .await;
}

#[tokio::test]
async fn dispatch_read_query_managed_agent_acp_inspect_uses_session_id_scope() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("1"))], async {
        let state = test_http_state_with_db();
        let request = WsRequest {
            id: "req-acp-inspect-alias".into(),
            method: "managed_agent.acp_inspect".into(),
            params: serde_json::json!({
                "session_id": "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
            }),
            trace_context: None,
        };

        let response = dispatch_read_query(&request, &state).await;

        assert!(response.error.is_none());
        let result = response.result.expect("ACP inspect response");
        assert_eq!(result["agents"].as_array().map(Vec::len), Some(0));
    })
    .await;
}

#[tokio::test]
async fn dispatch_read_query_managed_agent_acp_inspect_rejects_legacy_require_session_id() {
    let state = test_http_state_with_db();
    let request = WsRequest {
        id: "req-acp-inspect-legacy-scope".into(),
        method: "managed_agent.acp_inspect".into(),
        params: serde_json::json!({
            "require_session_id": "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
        }),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;

    let error = response.error.expect("invalid params error");
    assert_eq!(error.code, "INVALID_PARAMS");
    assert_eq!(
        error.message,
        "require_session_id is no longer supported; use session_id"
    );
}

#[tokio::test]
async fn dispatch_read_query_managed_agent_acp_transcript_returns_only_acp_rows() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("1"))], async {
        let state = test_http_state_with_async_db_timeline().await;
        seed_sample_acp_transcript(&state);
        let request = WsRequest {
            id: "req-acp-transcript".into(),
            method: "managed_agent.acp_transcript".into(),
            params: serde_json::json!({
                "session_id": "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
            }),
            trace_context: None,
        };

        let response = dispatch_read_query(&request, &state).await;

        assert!(response.error.is_none());
        let result = response.result.expect("ACP transcript response");
        let Value::Array(entries) = result["entries"].clone() else {
            panic!("expected ACP transcript entries array");
        };
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0]["kind"].as_str(), Some("assistant_text"));
        assert_eq!(
            entries[0]["session_id"].as_str(),
            Some("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4")
        );
        assert_eq!(entries[0]["agent_id"].as_str(), Some("codex-worker"));
        assert_eq!(entries[0]["summary"].as_str(), Some("ACP transcript line"));
        assert_eq!(entries[0]["payload"]["runtime"].as_str(), Some("gemini"));
    })
    .await;
}

#[tokio::test]
async fn dispatch_read_query_managed_agent_acp_transcript_uses_session_id_scope() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("1"))], async {
        let state = test_http_state_with_async_db_timeline().await;
        seed_sample_acp_transcript(&state);
        let request = WsRequest {
            id: "req-acp-transcript-alias".into(),
            method: "managed_agent.acp_transcript".into(),
            params: serde_json::json!({
                "session_id": "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
            }),
            trace_context: None,
        };

        let response = dispatch_read_query(&request, &state).await;

        assert!(response.error.is_none());
        let result = response.result.expect("ACP transcript response");
        let Value::Array(entries) = result["entries"].clone() else {
            panic!("expected ACP transcript entries array");
        };
        assert_eq!(entries.len(), 1);
    })
    .await;
}

#[tokio::test]
async fn dispatch_read_query_managed_agent_acp_transcript_rejects_legacy_require_session_id() {
    let state = test_http_state_with_db();
    let request = WsRequest {
        id: "req-acp-transcript-legacy-scope".into(),
        method: "managed_agent.acp_transcript".into(),
        params: serde_json::json!({
            "require_session_id": "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
        }),
        trace_context: None,
    };

    let response = dispatch_read_query(&request, &state).await;

    let error = response.error.expect("invalid params error");
    assert_eq!(error.code, "INVALID_PARAMS");
    assert_eq!(
        error.message,
        "require_session_id is no longer supported; use session_id"
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
            "session_id": "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
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
            "session_id": "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
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

fn seed_sample_acp_transcript(state: &DaemonHttpState) {
    let db_path = state.db_path.as_ref().expect("db path");
    let db = DaemonDb::open(db_path).expect("open file db");
    let mut session = db
        .load_session_state("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4")
        .expect("load sample session")
        .expect("sample session present");
    let agent = session
        .agents
        .get_mut("codex-worker")
        .expect("sample codex worker present");
    agent.runtime = "gemini".into();
    agent.managed_agent = Some(crate::session::types::ManagedAgentRef::acp("acp-agent-1"));
    db.save_session_state("project-abc123", &session)
        .expect("save managed ACP session");
    db.sync_conversation_events(
        "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
        "codex-worker",
        "gemini",
        &[ConversationEvent {
            timestamp: Some("2026-04-13T19:03:00Z".into()),
            sequence: 7,
            kind: ConversationEventKind::AssistantText {
                content: "ACP transcript line".into(),
            },
            agent: "codex-worker".into(),
            session_id: "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".into(),
        }],
    )
    .expect("sync ACP conversation events");
}
