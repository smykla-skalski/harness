use clap::ValueEnum;
use serde_json::json;

use crate::agents::kind::{DisconnectReason, RuntimeKind};
use crate::hooks::adapters::HookAgent;

use super::test_support::{agent_registration, persona};
use super::{AgentPersona, AgentRegistration, AgentStatus, PersonaSymbol, SessionRole};

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
        "agent_id": "a1",
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
fn agent_registration_with_persona_deserializes() {
    let json = r#"{
        "agent_id": "a1",
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
}
