use crate::agents::runtime::signal::AckResult;
use crate::session::types::SessionRole;

use serde_json::json;

use super::*;

#[test]
fn session_start_request_round_trips() {
    let request = SessionStartRequest {
        title: "auth fix session".into(),
        context: "fix auth bug".into(),
        runtime: "claude".into(),
        session_id: Some("my-session".into()),
        project_dir: "/tmp/project".into(),
        policy_preset: Some("swarm-default".into()),
    };
    let json = serde_json::to_value(&request).expect("serialize");
    assert_eq!(json["title"], "auth fix session");
    assert_eq!(json["context"], "fix auth bug");
    assert_eq!(json["runtime"], "claude");
    assert_eq!(json["session_id"], "my-session");
    assert_eq!(json["project_dir"], "/tmp/project");
    assert_eq!(json["policy_preset"], "swarm-default");

    let back: SessionStartRequest = serde_json::from_value(json).expect("deserialize");
    assert_eq!(back.title, "auth fix session");
    assert_eq!(back.context, "fix auth bug");
    assert_eq!(back.session_id.as_deref(), Some("my-session"));
    assert_eq!(back.policy_preset.as_deref(), Some("swarm-default"));
}

#[test]
fn session_start_request_optional_session_id() {
    let json = json!({
        "context": "goal",
        "runtime": "codex",
        "project_dir": "/tmp/p"
    });
    let request: SessionStartRequest = serde_json::from_value(json).expect("deserialize");
    assert!(request.session_id.is_none());
    assert!(request.policy_preset.is_none());

    let serialized = serde_json::to_value(&request).expect("serialize");
    assert!(serialized.get("session_id").is_none());
}

#[test]
fn session_join_request_round_trips() {
    let request = SessionJoinRequest {
        runtime: "codex".into(),
        role: SessionRole::Worker,
        fallback_role: Some(SessionRole::Observer),
        capabilities: vec!["general".into()],
        name: Some("codex worker".into()),
        project_dir: "/tmp/project".into(),
        persona: None,
    };
    let json = serde_json::to_value(&request).expect("serialize");
    assert_eq!(json["role"], "worker");

    let back: SessionJoinRequest = serde_json::from_value(json).expect("deserialize");
    assert_eq!(back.runtime, "codex");
    assert_eq!(back.role, SessionRole::Worker);
    assert_eq!(back.fallback_role, Some(SessionRole::Observer));
    assert_eq!(back.capabilities, vec!["general"]);
}

#[test]
fn session_join_request_defaults_empty_capabilities() {
    let json = json!({
        "runtime": "claude",
        "role": "observer",
        "project_dir": "/tmp/p"
    });
    let request: SessionJoinRequest = serde_json::from_value(json).expect("deserialize");
    assert!(request.capabilities.is_empty());
    assert!(request.fallback_role.is_none());
    assert!(request.name.is_none());
}

#[test]
fn session_leave_request_round_trips() {
    let request = SessionLeaveRequest {
        agent_id: "codex-leader".into(),
    };
    let json = serde_json::to_value(&request).expect("serialize");
    assert_eq!(json["agent_id"], "codex-leader");

    let back: SessionLeaveRequest = serde_json::from_value(json).expect("deserialize");
    assert_eq!(back.agent_id, "codex-leader");
}

#[test]
fn signal_ack_request_round_trips() {
    let request = SignalAckRequest {
        agent_id: "codex-worker".into(),
        signal_id: "sig-123".into(),
        result: AckResult::Accepted,
        project_dir: "/tmp/project".into(),
    };
    let json = serde_json::to_value(&request).expect("serialize");
    assert_eq!(json["result"], "accepted");

    let back: SignalAckRequest = serde_json::from_value(json).expect("deserialize");
    assert_eq!(back.result, AckResult::Accepted);
}

#[test]
fn session_mutation_response_contains_state() {
    let json = json!({
        "state": {
            "schema_version": 3,
            "state_version": 1,
            "session_id": "sess-1",
            "context": "test",
            "status": "active",
            "created_at": "2024-01-01T00:00:00Z",
            "updated_at": "2024-01-01T00:00:00Z",
            "agents": {},
            "tasks": {},
            "metrics": {
                "agent_count": 0,
                "active_agent_count": 0,
                "open_task_count": 0,
                "in_progress_task_count": 0,
                "blocked_task_count": 0,
                "completed_task_count": 0
            }
        }
    });
    let response: SessionMutationResponse = serde_json::from_value(json).expect("deserialize");
    assert_eq!(response.state.session_id, "sess-1");
}
