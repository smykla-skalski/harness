use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Supported hook transports/adapters.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
#[value(rename_all = "kebab-case")]
pub enum HookAgent {
    Claude,
    Copilot,
    Codex,
    Gemini,
    #[value(name = "vibe")]
    Vibe,
    #[value(name = "opencode")]
    OpenCode,
}

/// Resolve a hook agent from a runtime name, including legacy aliases.
#[must_use]
pub fn hook_agent_for_runtime_name(name: &str) -> Option<HookAgent> {
    match name {
        "claude" => Some(HookAgent::Claude),
        "codex" => Some(HookAgent::Codex),
        "gemini" => Some(HookAgent::Gemini),
        "copilot" => Some(HookAgent::Copilot),
        "vibe" => Some(HookAgent::Vibe),
        "opencode" => Some(HookAgent::OpenCode),
        _ => None,
    }
}

/// Serializable runtime capability metadata exposed to daemon clients.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "each bool is an independent capability flag in a serialized protocol type"
)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct RuntimeCapabilities {
    pub runtime: String,
    pub supports_native_transcript: bool,
    pub supports_signal_delivery: bool,
    pub supports_context_injection: bool,
    pub typical_signal_latency_seconds: u64,
    #[serde(default)]
    pub supports_readiness_signal: bool,
    #[serde(default)]
    pub hook_points: Vec<HookIntegrationDescriptor>,
}

/// One user-visible hook interception point for signal pickup.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct HookIntegrationDescriptor {
    pub name: String,
    pub typical_latency_seconds: u64,
    pub supports_context_injection: bool,
}

/// A signal sent to an agent session.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct Signal {
    pub signal_id: String,
    pub version: u32,
    pub created_at: String,
    pub expires_at: String,
    pub source_agent: String,
    pub command: String,
    pub priority: SignalPriority,
    pub payload: SignalPayload,
    pub delivery: DeliveryConfig,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub enum SignalPriority {
    Low,
    Normal,
    High,
    Urgent,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct SignalPayload {
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action_hint: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub related_files: Vec<String>,
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub metadata: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct DeliveryConfig {
    pub max_retries: u32,
    #[serde(default)]
    pub retry_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct SignalAck {
    pub signal_id: String,
    pub acknowledged_at: String,
    pub result: AckResult,
    pub agent: String,
    pub session_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub enum AckResult {
    Accepted,
    Rejected,
    Deferred,
    Expired,
}

/// Whether a signal belongs to one orchestration session when it was loaded
/// from a possibly shared runtime-session signal directory.
#[must_use]
pub fn signal_matches_session(
    signal: &Signal,
    acknowledgment: Option<&SignalAck>,
    orchestration_session_id: &str,
    agent_id: &str,
    signal_session_id: &str,
) -> bool {
    if signal_session_id == orchestration_session_id {
        return true;
    }

    if let Some(idempotency_key) = signal.delivery.idempotency_key.as_deref() {
        let mut parts = idempotency_key.splitn(3, ':');
        return parts.next() == Some(orchestration_session_id)
            && parts.next() == Some(agent_id)
            && parts.next().is_some();
    }

    acknowledgment.is_some_and(|ack| ack.session_id == orchestration_session_id)
}
