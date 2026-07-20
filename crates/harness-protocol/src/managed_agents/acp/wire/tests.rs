use super::{
    AcpAgentInspectSnapshot, AcpAgentSnapshot, AcpAgentStartRequest, AcpPermissionBatch,
    AcpPermissionItem, BridgeAcpStartRequest,
};
use crate::managed_agents::acp::{AcpPermissionOption, AcpPermissionOptionKind};
use crate::session::{AgentStatus, SessionRole};

fn start_request() -> AcpAgentStartRequest {
    AcpAgentStartRequest {
        agent: "copilot".into(),
        role: SessionRole::Reviewer,
        fallback_role: Some(SessionRole::Observer),
        capabilities: vec!["fs.read".into()],
        name: Some("Copilot Reviewer".into()),
        prompt: Some("Review the change".into()),
        project_dir: Some("/tmp/project".into()),
        persona: Some("reviewer".into()),
        task_id: Some("task-1".into()),
        board_item_id: Some("board-item-1".into()),
        workflow_execution_id: Some("workflow-1".into()),
        model: Some("gpt-5.4".into()),
        effort: Some("high".into()),
        allow_custom_model: true,
        record_permissions: true,
    }
}

fn snapshot() -> AcpAgentSnapshot {
    AcpAgentSnapshot {
        acp_id: "acp-1".into(),
        session_id: "session-1".into(),
        agent_id: "worker-1".into(),
        display_name: "Copilot".into(),
        status: AgentStatus::Active,
        pid: 42,
        pgid: 42,
        project_dir: "/tmp/project".into(),
        process_key: "proc-1".into(),
        pending_permissions: 0,
        permission_queue_depth: 0,
        pending_permission_batches: Vec::new(),
        permission_mode: String::new(),
        permission_log_path: None,
        terminal_count: 0,
        created_at: "2026-05-06T00:00:00Z".into(),
        updated_at: "2026-05-06T00:00:01Z".into(),
    }
}

fn inspect_snapshot() -> AcpAgentInspectSnapshot {
    AcpAgentInspectSnapshot {
        acp_id: "acp-1".into(),
        session_id: "session-1".into(),
        agent_id: "worker-1".into(),
        display_name: "Copilot".into(),
        pid: 42,
        pgid: 42,
        process_key: String::new(),
        uptime_ms: 1_000,
        last_update_at: "2026-05-06T00:00:01Z".into(),
        last_client_call_at: None,
        watchdog_state: "healthy".into(),
        permission_mode: String::new(),
        permission_log_path: None,
        pending_permissions: 0,
        permission_queue_depth: 0,
        terminal_count: 0,
        prompt_deadline_remaining_ms: 10_000,
        handshake: None,
        session_state: None,
    }
}

#[test]
fn acp_start_request_uses_only_canonical_descriptor_id() {
    let value = serde_json::to_value(start_request()).expect("serialize ACP start request");

    assert_eq!(value["descriptor_id"], "copilot");
    assert!(value.get("agent").is_none());
    assert_eq!(value["role"], "reviewer");
    assert_eq!(value["fallback_role"], "observer");
    assert_eq!(value["record_permissions"], true);

    let decoded: AcpAgentStartRequest =
        serde_json::from_value(value).expect("round-trip ACP start request");
    assert_eq!(decoded, start_request());
}

#[test]
fn acp_start_request_rejects_missing_empty_and_alias_descriptors() {
    for value in [
        serde_json::json!({"role": "reviewer"}),
        serde_json::json!({"descriptor_id": "  "}),
        serde_json::json!({"descriptor_id": "copilot", "agent": "copilot"}),
    ] {
        let error = serde_json::from_value::<AcpAgentStartRequest>(value)
            .expect_err("invalid descriptor must fail");
        assert!(
            error.to_string().contains("descriptor_id")
                || error.to_string().contains("unknown field")
        );
    }
}

#[test]
fn permission_batch_uses_explicit_managed_agent_identity() {
    let batch = AcpPermissionBatch {
        batch_id: "batch-1".into(),
        acp_id: "acp-1".into(),
        session_id: "session-1".into(),
        requests: Vec::new(),
        created_at: "2026-05-06T00:00:00Z".into(),
        expires_at: "2026-05-06T00:05:00Z".into(),
    };

    let value = serde_json::to_value(&batch).expect("serialize permission batch");
    assert_eq!(value["managed_agent_id"], "acp-1");
    assert_eq!(value["managed_agent_family"], "acp");
    assert!(value.get("acp_id").is_none());
    assert_eq!(
        serde_json::from_value::<AcpPermissionBatch>(value).expect("round-trip batch"),
        batch
    );
}

#[test]
fn permission_option_matches_acp_runtime_json_shape() {
    let item = AcpPermissionItem {
        request_id: "request-1".into(),
        session_id: "session-1".into(),
        tool_call: serde_json::json!({"title": "read file"}),
        options: vec![AcpPermissionOption {
            option_id: "allow-once".into(),
            name: "Allow once".into(),
            kind: AcpPermissionOptionKind::AllowOnce,
            meta: None,
        }],
    };

    let value = serde_json::to_value(&item).expect("serialize permission item");
    assert_eq!(value["options"][0]["optionId"], "allow-once");
    assert_eq!(value["options"][0]["name"], "Allow once");
    assert_eq!(value["options"][0]["kind"], "allow_once");
    assert!(value["options"][0].get("_meta").is_none());
    assert_eq!(
        serde_json::from_value::<AcpPermissionItem>(value).expect("round-trip permission item"),
        item
    );
}

#[test]
fn permission_batch_rejects_missing_or_non_acp_family() {
    let base = serde_json::json!({
        "batch_id": "batch-1",
        "managed_agent_id": "acp-1",
        "managed_agent_family": "acp",
        "session_id": "session-1",
        "requests": [],
        "created_at": "2026-05-06T00:00:00Z",
        "expires_at": "2026-05-06T00:05:00Z"
    });
    let mut missing = base.clone();
    missing
        .as_object_mut()
        .expect("object")
        .remove("managed_agent_family");
    let mut wrong = base;
    wrong["managed_agent_family"] = serde_json::json!("tui");

    for value in [missing, wrong] {
        let error = serde_json::from_value::<AcpPermissionBatch>(value)
            .expect_err("invalid family must fail");
        assert!(error.to_string().contains("managed_agent_family"));
    }
}

#[test]
fn snapshots_use_explicit_identity_and_preserve_legacy_defaults() {
    let value = serde_json::to_value(snapshot()).expect("serialize ACP snapshot");
    assert_eq!(value["managed_agent_id"], "acp-1");
    assert_eq!(value["managed_agent_family"], "acp");
    assert_eq!(value["session_agent_id"], "worker-1");
    assert!(value.get("acp_id").is_none());
    assert!(value.get("agent_id").is_none());
    assert!(value.get("permission_mode").is_none());

    let decoded: AcpAgentSnapshot = serde_json::from_value(value).expect("round-trip snapshot");
    assert_eq!(decoded, snapshot());
}

#[test]
fn inspect_snapshots_use_explicit_identity_and_default_optional_state() {
    let value = serde_json::to_value(inspect_snapshot()).expect("serialize inspect snapshot");
    assert_eq!(value["managed_agent_id"], "acp-1");
    assert_eq!(value["managed_agent_family"], "acp");
    assert_eq!(value["session_agent_id"], "worker-1");
    assert!(value.get("process_key").is_none());
    assert!(value.get("permission_mode").is_none());

    let decoded: AcpAgentInspectSnapshot =
        serde_json::from_value(value).expect("round-trip inspect snapshot");
    assert_eq!(decoded, inspect_snapshot());
}

#[test]
fn snapshots_reject_wrong_managed_agent_family() {
    let mut value = serde_json::to_value(snapshot()).expect("serialize ACP snapshot");
    value["managed_agent_family"] = serde_json::json!("tui");
    let error =
        serde_json::from_value::<AcpAgentSnapshot>(value).expect_err("non-ACP snapshot must fail");
    assert!(
        error
            .to_string()
            .contains("managed_agent_family must be 'acp'")
    );
}

#[test]
fn bridge_start_accepts_legacy_inner_alias_and_defaults_secret_absent() {
    let request: BridgeAcpStartRequest = serde_json::from_value(serde_json::json!({
        "session_id": "session-1",
        "request": {"agent": "copilot"},
        "disable_pooling": true
    }))
    .expect("decode legacy bridge request");

    assert_eq!(request.request.agent, "copilot");
    assert!(request.disable_pooling);
    assert!(request.openrouter_token.is_none());
}

#[test]
fn bridge_start_round_trips_secret_without_exposing_it_in_debug() {
    let request = BridgeAcpStartRequest {
        session_id: "session-1".into(),
        request: start_request(),
        disable_pooling: false,
        openrouter_token: Some("super-secret-token".into()),
    };
    let value = serde_json::to_value(&request).expect("serialize bridge request");
    assert_eq!(value["openrouter_token"], "super-secret-token");
    assert_eq!(
        serde_json::from_value::<BridgeAcpStartRequest>(value).expect("round-trip bridge request"),
        request
    );

    let debug = format!("{request:?}");
    assert!(debug.contains("[REDACTED]"));
    assert!(!debug.contains("super-secret-token"));
}

#[test]
fn bridge_start_omits_absent_secret() {
    let request = BridgeAcpStartRequest {
        session_id: "session-1".into(),
        request: start_request(),
        disable_pooling: false,
        openrouter_token: None,
    };

    let value = serde_json::to_value(request).expect("serialize bridge request");
    assert!(value.get("openrouter_token").is_none());
}

#[test]
fn bridge_start_decode_errors_never_include_the_secret() {
    let secret = "never-print-this-token";
    let error = serde_json::from_value::<BridgeAcpStartRequest>(serde_json::json!({
        "session_id": "session-1",
        "request": {"descriptor_id": ""},
        "openrouter_token": secret
    }))
    .expect_err("invalid descriptor must fail");

    assert!(!error.to_string().contains(secret));
}
