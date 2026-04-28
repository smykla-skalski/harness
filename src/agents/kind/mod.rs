//! Runtime identity for an agent registered in a session.
//!
//! Paradigm shift, restated: harness is moving from TUI-wrapper (spawn a
//! binary in a PTY, scrape its transcript) to agent-host (speak ACP JSON-RPC
//! over stdio and actively service `fs/*`, `terminal/*`,
//! `session/request_permission`). [`RuntimeKind`] is the first leg of that
//! move. It tags every registration with the transport family up front so
//! downstream code never has to parse `acp:` string prefixes or guess which
//! call paths apply.
//!
//! The on-disk shape is `{ "kind": "tui", "id": "<name>" }` for the existing
//! TUI-hook runtimes, and `{ "kind": "acp", "id": "<descriptor-id>" }` for
//! ACP descriptors. Bare-string entries from pre-Chunk-2 storage deserialise
//! through a legacy reader: known TUI names become `Tui(HookAgent)`,
//! everything else becomes `Acp(AcpAgentId)` so unknown legacy values do not
//! crash the load path.
//!
//! [`DisconnectReason`] lives in [`disconnect`]; re-exported here so
//! callers stay on the two-segment `crate::agents::kind::DisconnectReason`
//! path.

mod disconnect;

pub use disconnect::DisconnectReason;

use std::fmt;

use serde::{Deserialize, Serialize, de, ser::SerializeStruct};
use tracing::warn;

use crate::agents::runtime::hook_agent_for_runtime_name;
use crate::hooks::adapters::HookAgent;

/// Identifier of an ACP descriptor. Matches `AcpAgentDescriptor::id`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct AcpAgentId(pub String);

impl AcpAgentId {
    #[must_use]
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        self.0.as_str()
    }
}

impl fmt::Display for AcpAgentId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<&str> for AcpAgentId {
    fn from(value: &str) -> Self {
        Self(value.to_string())
    }
}

/// Tagged runtime identity. `Tui` is the legacy PTY-scrape transport;
/// `Acp` is the JSON-RPC agent-host transport.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuntimeKind {
    /// PTY-scraped TUI agent. `id` is the legacy lowercase name (e.g.
    /// `claude`, `codex`, `copilot`).
    Tui(HookAgent),
    /// ACP agent. `id` matches an `AcpAgentDescriptor::id` from the catalog.
    Acp(AcpAgentId),
}

impl RuntimeKind {
    /// Render the runtime's stable string identifier.
    ///
    /// For TUI runtimes this is the lowercase name used everywhere downstream
    /// (`claude`, `codex`, …). For ACP runtimes this is the descriptor id.
    /// Use this when you need to call out to legacy `&str`-keyed lookups
    /// (`runtime_for_name`, signal records, observe scans).
    #[must_use]
    pub fn runtime_name(&self) -> &str {
        match self {
            Self::Tui(agent) => hook_agent_name(*agent),
            Self::Acp(id) => id.as_str(),
        }
    }

    /// Convenience: is this a TUI-hook runtime?
    #[must_use]
    pub const fn is_tui(&self) -> bool {
        matches!(self, Self::Tui(_))
    }

    /// Convenience: is this an ACP runtime?
    #[must_use]
    pub const fn is_acp(&self) -> bool {
        matches!(self, Self::Acp(_))
    }

    /// Borrow the TUI hook agent if this is a TUI runtime.
    #[must_use]
    pub const fn as_hook_agent(&self) -> Option<HookAgent> {
        match self {
            Self::Tui(agent) => Some(*agent),
            Self::Acp(_) => None,
        }
    }

    /// Construct a TUI runtime from a [`HookAgent`].
    #[must_use]
    pub const fn tui(agent: HookAgent) -> Self {
        Self::Tui(agent)
    }

    /// Construct an ACP runtime from a descriptor id.
    #[must_use]
    pub fn acp(id: impl Into<String>) -> Self {
        Self::Acp(AcpAgentId::new(id))
    }
}

/// Render the lowercase string name used everywhere `&str` runtime ids are
/// compared. Kept private to this module so the canonical mapping lives next
/// to [`RuntimeKind`].
fn hook_agent_name(agent: HookAgent) -> &'static str {
    match agent {
        HookAgent::Claude => "claude",
        HookAgent::Codex => "codex",
        HookAgent::Gemini => "gemini",
        HookAgent::Copilot => "copilot",
        HookAgent::Vibe => "vibe",
        HookAgent::OpenCode => "opencode",
    }
}

impl fmt::Display for RuntimeKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.runtime_name())
    }
}

impl From<HookAgent> for RuntimeKind {
    fn from(agent: HookAgent) -> Self {
        Self::Tui(agent)
    }
}

/// Legacy reader: bare-string runtime ids from pre-Chunk-2 storage. Known
/// TUI names map to [`RuntimeKind::Tui`]; anything else falls back to
/// [`RuntimeKind::Acp`] so unrecognised legacy values do not crash the load
/// path.
///
/// The migrator (`storage::migrations::migrate_v10_to_v11`) rewrites every
/// legacy entry up front, so this fallback should never fire in production.
/// When it does, the unknown name is emitted as a `warn!` so schema drift
/// surfaces in operator logs instead of silently coercing to a phantom ACP
/// registration. Test fixtures and the deserializer's `Legacy` arm use this
/// path intentionally; live-registration code paths must not depend on it.
impl From<&str> for RuntimeKind {
    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn from(value: &str) -> Self {
        if let Some(agent) = hook_agent_for_runtime_name(value) {
            return Self::Tui(agent);
        }
        warn!(
            runtime = %value,
            "RuntimeKind::from(&str) fell through to Acp(_) for unrecognised name; \
             expected only for legacy storage rows the migrator missed",
        );
        Self::Acp(AcpAgentId::new(value))
    }
}

impl From<String> for RuntimeKind {
    fn from(value: String) -> Self {
        Self::from(value.as_str())
    }
}

impl PartialEq<str> for RuntimeKind {
    fn eq(&self, other: &str) -> bool {
        // Comparison by the legacy bare-string view. Matches TUI agents by
        // their lowercase name; ACP agents match their descriptor id.
        self.runtime_name() == other
    }
}

impl PartialEq<&str> for RuntimeKind {
    fn eq(&self, other: &&str) -> bool {
        self.runtime_name() == *other
    }
}

impl PartialEq<String> for RuntimeKind {
    fn eq(&self, other: &String) -> bool {
        self.runtime_name() == other.as_str()
    }
}

// --- Serde -----------------------------------------------------------------

const KIND_TUI: &str = "tui";
const KIND_ACP: &str = "acp";

impl Serialize for RuntimeKind {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut state = serializer.serialize_struct("RuntimeKind", 2)?;
        match self {
            Self::Tui(agent) => {
                state.serialize_field("kind", KIND_TUI)?;
                state.serialize_field("id", hook_agent_name(*agent))?;
            }
            Self::Acp(id) => {
                state.serialize_field("kind", KIND_ACP)?;
                state.serialize_field("id", id.as_str())?;
            }
        }
        state.end()
    }
}

#[derive(Deserialize)]
#[serde(untagged)]
enum RuntimeKindOnDisk {
    Tagged { kind: String, id: String },
    Legacy(String),
}

impl<'de> Deserialize<'de> for RuntimeKind {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        match RuntimeKindOnDisk::deserialize(deserializer)? {
            RuntimeKindOnDisk::Tagged { kind, id } => match kind.as_str() {
                KIND_TUI => hook_agent_for_runtime_name(&id)
                    .map(Self::Tui)
                    .ok_or_else(|| de::Error::custom(format!("unknown tui runtime id '{id}'"))),
                KIND_ACP => Ok(Self::Acp(AcpAgentId::new(id))),
                other => Err(de::Error::custom(format!(
                    "unknown runtime kind tag '{other}'"
                ))),
            },
            RuntimeKindOnDisk::Legacy(name) => Ok(Self::from(name.as_str())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tui_round_trips_through_tagged_form() {
        let kind = RuntimeKind::Tui(HookAgent::Claude);
        let json = serde_json::to_string(&kind).expect("serialise");
        assert_eq!(json, r#"{"kind":"tui","id":"claude"}"#);
        let parsed: RuntimeKind = serde_json::from_str(&json).expect("deserialise");
        assert_eq!(parsed, kind);
    }

    #[test]
    fn acp_round_trips_through_tagged_form() {
        let kind = RuntimeKind::Acp(AcpAgentId::new("copilot"));
        let json = serde_json::to_string(&kind).expect("serialise");
        assert_eq!(json, r#"{"kind":"acp","id":"copilot"}"#);
        let parsed: RuntimeKind = serde_json::from_str(&json).expect("deserialise");
        assert_eq!(parsed, kind);
    }

    #[test]
    fn legacy_bare_string_known_tui_name_loads_as_tui() {
        let parsed: RuntimeKind = serde_json::from_str(r#""codex""#).expect("legacy deserialise");
        assert_eq!(parsed, RuntimeKind::Tui(HookAgent::Codex));
    }

    #[test]
    fn legacy_bare_string_unknown_name_loads_as_acp() {
        let parsed: RuntimeKind = serde_json::from_str(r#""mystery""#).expect("legacy deserialise");
        assert_eq!(parsed, RuntimeKind::Acp(AcpAgentId::new("mystery")));
    }

    #[test]
    fn unknown_tagged_kind_errors() {
        let err = serde_json::from_str::<RuntimeKind>(r#"{"kind":"smoke","id":"x"}"#).unwrap_err();
        assert!(err.to_string().contains("unknown runtime kind"));
    }

    #[test]
    fn from_str_returns_tui_for_known_names() {
        assert_eq!(
            RuntimeKind::from("claude"),
            RuntimeKind::Tui(HookAgent::Claude)
        );
    }

    #[test]
    fn runtime_name_round_trips_for_tui() {
        for kind in [
            RuntimeKind::Tui(HookAgent::Claude),
            RuntimeKind::Tui(HookAgent::Codex),
            RuntimeKind::Tui(HookAgent::Gemini),
            RuntimeKind::Tui(HookAgent::Copilot),
            RuntimeKind::Tui(HookAgent::Vibe),
            RuntimeKind::Tui(HookAgent::OpenCode),
        ] {
            assert_eq!(RuntimeKind::from(kind.runtime_name()), kind);
        }
    }

    #[test]
    fn partial_eq_with_str_compares_runtime_name() {
        assert!(RuntimeKind::Tui(HookAgent::Codex) == "codex");
        assert!(RuntimeKind::Tui(HookAgent::Claude) != "codex");
        assert!(RuntimeKind::Acp(AcpAgentId::new("copilot")) == "copilot");
    }
}
