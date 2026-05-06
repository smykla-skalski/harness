use clap::ValueEnum;
use serde_json::json;

use crate::agents::kind::{DisconnectReason, RuntimeKind};
use crate::hooks::adapters::HookAgent;

use super::test_support::{agent_registration, persona};
use super::{
    AgentDescriptorId, AgentPersona, AgentRegistration, AgentStatus, ManagedAgentId,
    ManagedAgentRef, PersonaSymbol, RuntimeSessionId, SessionAgentId, SessionRole,
};

#[test]
fn session_role_clap_value_enum() {
    let variants = SessionRole::value_variants();
    assert_eq!(variants.len(), 5);
}

#[test]
fn idle_agent_status_serde_round_trip() {
    let status: AgentStatus = serde_json::from_str(r#""idle""#).expect("deserializes idle");
    assert_eq!(status, AgentStatus::Idle);
    let serialized = serde_json::to_string(&status).expect("serializes");
    assert_eq!(serialized, r#""idle""#);
}

#[test]
fn disconnected_agent_status_serializes_reason_and_stderr_tail() {
    let status = AgentStatus::Disconnected {
        reason: DisconnectReason::ProcessExited {
            code: Some(137),
            signal: None,
        },
        stderr_tail: Some("killed".to_string()),
    };

    let serialized = serde_json::to_value(&status).expect("serializes disconnected status");

    assert_eq!(
        serialized,
        json!({
            "state": "disconnected",
            "reason": {
                "kind": "process_exited",
                "code": 137
            },
            "stderr_tail": "killed"
        })
    );
}

#[test]
fn legacy_disconnected_agent_status_deserializes_with_unknown_reason() {
    let status: AgentStatus =
        serde_json::from_str(r#""disconnected""#).expect("deserializes legacy disconnected");

    assert_eq!(status, AgentStatus::disconnected_unknown());
}

#[test]
fn persona_symbol_sf_symbol_serde_round_trip() {
    let symbol = PersonaSymbol::SfSymbol {
        name: "magnifyingglass.circle.fill".into(),
    };
    let json = serde_json::to_string(&symbol).expect("serializes");
    assert!(
        json.contains(r#""type":"sf_symbol""#),
        "tagged as sf_symbol"
    );
    assert!(
        json.contains(r#""name":"magnifyingglass.circle.fill""#),
        "contains name"
    );
    let parsed: PersonaSymbol = serde_json::from_str(&json).expect("deserializes");
    assert_eq!(parsed, symbol);
}

#[test]
fn persona_symbol_asset_serde_round_trip() {
    let symbol = PersonaSymbol::Asset {
        name: "custom-icon".into(),
    };
    let json = serde_json::to_string(&symbol).expect("serializes");
    assert!(json.contains(r#""type":"asset""#), "tagged as asset");
    assert!(json.contains(r#""name":"custom-icon""#), "contains name");
    let parsed: PersonaSymbol = serde_json::from_str(&json).expect("deserializes");
    assert_eq!(parsed, symbol);
}

#[test]
fn persona_symbol_rejects_unknown_type() {
    let result = serde_json::from_str::<PersonaSymbol>(r#"{"type":"unknown","name":"x"}"#);
    assert!(result.is_err(), "unknown type should fail to deserialize");
}

#[test]
fn agent_persona_serde_round_trip() {
    let reviewer = persona("code-reviewer");
    let json = serde_json::to_string(&reviewer).expect("serializes");
    let parsed: AgentPersona = serde_json::from_str(&json).expect("deserializes");
    assert_eq!(parsed, reviewer);
}

#[test]
fn agent_persona_with_asset_serde_round_trip() {
    let persona = AgentPersona {
        identifier: "custom".into(),
        name: "Custom".into(),
        symbol: PersonaSymbol::Asset {
            name: "custom-icon".into(),
        },
        description: "A custom persona".into(),
    };
    let json = serde_json::to_string(&persona).expect("serializes");
    let parsed: AgentPersona = serde_json::from_str(&json).expect("deserializes");
    assert_eq!(parsed, persona);
}

#[test]
fn agent_registration_without_persona_deserializes() {
    let json = r#"{
        "session_agent_id": "a1",
        "name": "agent",
        "runtime": "codex",
        "role": "worker",
        "capabilities": [],
        "joined_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "status": "active"
    }"#;
    let reg: AgentRegistration = serde_json::from_str(json).expect("deserializes");
    assert_eq!(reg.agent_id, "a1");
    assert_eq!(reg.runtime, RuntimeKind::Tui(HookAgent::Codex));
    assert!(
        reg.persona.is_none(),
        "missing persona should default to None"
    );
}

#[test]
fn agent_registration_with_canonical_identity_fields_deserializes() {
    let json = r#"{
        "session_agent_id": "a1",
        "name": "agent",
        "runtime": "codex",
        "role": "worker",
        "capabilities": [],
        "joined_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "status": "active",
        "runtime_session_id": "runtime-1"
    }"#;
    let reg: AgentRegistration = serde_json::from_str(json).expect("deserializes");
    assert_eq!(reg.agent_id, "a1");
    assert_eq!(reg.agent_session_id.as_deref(), Some("runtime-1"));
}

#[test]
fn agent_registration_rejects_legacy_identity_aliases() {
    let json = r#"{
        "agent_id": "a1",
        "name": "agent",
        "runtime": "codex",
        "role": "worker",
        "capabilities": [],
        "joined_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "status": "active",
        "agent_session_id": "runtime-1"
    }"#;
    let error = serde_json::from_str::<AgentRegistration>(json).expect_err("legacy fields fail");
    assert!(
        error.to_string().contains("session_agent_id"),
        "expected canonical field error, got {error}"
    );
}

#[test]
fn agent_registration_with_persona_deserializes() {
    let json = r#"{
        "session_agent_id": "a1",
        "name": "agent",
        "runtime": "codex",
        "role": "worker",
        "capabilities": [],
        "joined_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "status": "active",
        "persona": {
            "identifier": "code-reviewer",
            "name": "Code Reviewer",
            "symbol": {"type": "sf_symbol", "name": "magnifyingglass.circle.fill"},
            "description": "Reviews code"
        }
    }"#;
    let reg: AgentRegistration = serde_json::from_str(json).expect("deserializes");
    let reviewer = reg.persona.expect("persona should be present");
    assert_eq!(reviewer.identifier, "code-reviewer");
    assert_eq!(reviewer.name, "Code Reviewer");
    assert_eq!(
        reviewer.symbol,
        PersonaSymbol::SfSymbol {
            name: "magnifyingglass.circle.fill".into()
        }
    );
}

#[test]
fn agent_registration_persona_skipped_when_none() {
    let reg = agent_registration("a1", "codex", SessionRole::Worker, AgentStatus::Active);
    let json = serde_json::to_string(&reg).expect("serializes");
    assert!(
        !json.contains("persona"),
        "persona key should be omitted when None"
    );
}

#[test]
fn agent_registration_runtime_serializes_as_tagged_kind() {
    let reg = agent_registration("a1", "codex", SessionRole::Worker, AgentStatus::Active);

    let json = serde_json::to_value(&reg).expect("serializes registration");

    assert_eq!(json["runtime"], json!({ "kind": "tui", "id": "codex" }));
    assert_eq!(json["session_agent_id"], "a1");
    assert!(json.get("agent_id").is_none());
}

#[test]
fn managed_agent_identity_accessors_keep_wire_shape() {
    let managed = ManagedAgentRef::acp("acp-1");

    assert_eq!(managed.managed_agent_id(), ManagedAgentId::from("acp-1"));
    assert_eq!(
        serde_json::to_value(&managed).expect("serializes managed agent"),
        json!({ "kind": "acp", "id": "acp-1" })
    );
}

#[test]
fn agent_registration_identity_accessors_classify_descriptor_runtime_ids() {
    let mut reg = agent_registration(
        "worker-1",
        "mystery-acp",
        SessionRole::Worker,
        AgentStatus::Active,
    );
    reg.agent_session_id = Some("runtime-1".into());
    reg.managed_agent = Some(ManagedAgentRef::acp("acp-1"));

    assert_eq!(reg.session_agent_id(), SessionAgentId::from("worker-1"));
    assert_eq!(
        reg.runtime_session_id(),
        Some(RuntimeSessionId::from("runtime-1"))
    );
    assert_eq!(reg.managed_agent_id(), Some(ManagedAgentId::from("acp-1")));
    assert_eq!(
        reg.agent_descriptor_id(),
        Some(AgentDescriptorId::from("mystery-acp"))
    );

    let json = serde_json::to_value(&reg).expect("serializes registration");
    assert_eq!(json["session_agent_id"], "worker-1");
    assert_eq!(json["runtime_session_id"], "runtime-1");
    assert_eq!(json["managed_agent_id"], "acp-1");
    assert_eq!(json["managed_agent_family"], "acp");
    assert_eq!(json["descriptor_id"], "mystery-acp");
    assert!(json.get("agent_id").is_none());
    assert!(json.get("agent_session_id").is_none());
}

#[test]
fn agent_registration_runtime_session_helpers_use_canonical_runtime_key() {
    let reg = agent_registration(
        "worker-1",
        "codex",
        SessionRole::Worker,
        AgentStatus::Active,
    );

    assert_eq!(reg.runtime_session_id(), None);
    assert_eq!(reg.runtime_session_key("sess-1"), "sess-1");
    assert!(reg.matches_runtime_session_id("sess-1", &RuntimeSessionId::from("sess-1")));

    let mut bound = reg.clone();
    bound.agent_session_id = Some("runtime-1".into());

    assert_eq!(
        bound.runtime_session_id(),
        Some(RuntimeSessionId::from("runtime-1"))
    );
    assert_eq!(bound.runtime_session_key("sess-1"), "runtime-1");
    assert!(bound.matches_runtime_session_id("sess-1", &RuntimeSessionId::from("runtime-1")));
    assert!(!bound.matches_runtime_session_id("sess-1", &RuntimeSessionId::from("sess-1")));
}
