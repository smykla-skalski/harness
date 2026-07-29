use serde_json::{Value, json};

use crate::daemon::protocol::WsRequest;

use super::super::{
    dispatch_managed_agent_interrupt_codex, dispatch_managed_agent_resolve_codex_approval,
    dispatch_managed_agent_start_codex, dispatch_managed_agent_steer_codex,
};

const SESSION_ID: &str = "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4";

fn request(method: &str, params: Value) -> WsRequest {
    WsRequest {
        id: format!("req-{method}"),
        method: method.to_string(),
        params,
        trace_context: None,
    }
}

#[tokio::test]
async fn codex_start_rebinds_actor_before_request_decoding() {
    let state = super::super::super::test_support::test_http_state_with_db();
    let request = request(
        "managed_agent.start_codex",
        json!({
            "session_id": SESSION_ID,
            "actor": 42,
            "prompt": " ",
            "mode": "report",
        }),
    );

    let response = dispatch_managed_agent_start_codex(&request, &state).await;

    let error = response.error.expect("empty-prompt error");
    assert_eq!(error.code, "WORKFLOW_PARSE");
    assert!(
        error.message.contains("codex prompt cannot be empty"),
        "unexpected error: {}",
        error.message
    );
}

#[tokio::test]
async fn codex_steer_requires_canonical_managed_agent_id() {
    let state = super::super::super::test_support::test_http_state_with_db();
    let request = request(
        "managed_agent.steer_codex",
        json!({
            "agent_id": "codex-run-1",
            "prompt": "continue",
        }),
    );

    let response = dispatch_managed_agent_steer_codex(&request, &state).await;

    let error = response.error.expect("missing managed agent id");
    assert_eq!(error.code, "MISSING_PARAM");
    assert_eq!(error.message, "missing managed_agent_id");
}

#[tokio::test]
async fn codex_interrupt_requires_canonical_managed_agent_id() {
    let state = super::super::super::test_support::test_http_state_with_db();
    let request = request(
        "managed_agent.interrupt_codex",
        json!({
            "agent_id": "codex-run-1",
        }),
    );

    let response = dispatch_managed_agent_interrupt_codex(&request, &state).await;

    let error = response.error.expect("missing managed agent id");
    assert_eq!(error.code, "MISSING_PARAM");
    assert_eq!(error.message, "missing managed_agent_id");
}

#[tokio::test]
async fn codex_approval_requires_approval_id_before_decision() {
    let state = super::super::super::test_support::test_http_state_with_db();
    let request = request(
        "managed_agent.resolve_codex_approval",
        json!({
            "managed_agent_id": "codex-run-1",
            "decision": "accept",
        }),
    );

    let response = dispatch_managed_agent_resolve_codex_approval(&request, &state).await;

    let error = response.error.expect("missing approval id");
    assert_eq!(error.code, "MISSING_PARAM");
    assert_eq!(error.message, "missing approval_id");
}

#[tokio::test]
async fn codex_approval_parses_valid_decision_after_ids() {
    let state = super::super::super::test_support::test_http_state_with_db();
    let request = request(
        "managed_agent.resolve_codex_approval",
        json!({
            "managed_agent_id": "missing-codex-run",
            "approval_id": "approval-1",
            "decision": "accept_for_session",
        }),
    );

    let response = dispatch_managed_agent_resolve_codex_approval(&request, &state).await;

    let error = response.error.expect("missing run after parse");
    assert_eq!(error.code, "KSRCLI090");
    assert!(
        error.message.contains("missing-codex-run"),
        "unexpected error: {}",
        error.message
    );
}
