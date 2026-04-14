use clap::ValueEnum;
use serde::{Deserialize, Serialize};

use crate::agents::runtime::RuntimeCapabilities;

/// An agent registered in a multi-agent session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentRegistration {
    pub agent_id: String,
    /// Human-readable display name.
    pub name: String,
    /// Agent runtime identifier (stored as string for forward compatibility).
    pub runtime: String,
    pub role: SessionRole,
    /// Free-form capability tags declared on join.
    #[serde(default)]
    pub capabilities: Vec<String>,
    pub joined_at: String,
    pub updated_at: String,
    pub status: AgentStatus,
    /// Link to the agent's individual session in the agents ledger.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_session_id: Option<String>,
    /// Most recent observed activity for this agent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_activity_at: Option<String>,
    /// Current assigned work item, when present.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_task_id: Option<String>,
    /// Runtime delivery and transcript features for UI badges.
    #[serde(default)]
    pub runtime_capabilities: RuntimeCapabilities,
    /// Optional persona assigned at agent join time.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub persona: Option<AgentPersona>,
}

/// A pending leadership transfer initiated by a non-leader actor.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingLeaderTransfer {
    pub requested_by: String,
    pub current_leader_id: String,
    pub new_leader_id: String,
    pub requested_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// Role an agent holds within a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum SessionRole {
    Leader,
    Observer,
    Worker,
    Reviewer,
    Improver,
}

/// Whether an agent is actively participating.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentStatus {
    Active,
    /// Agent is alive but has not used tools recently.
    Idle,
    Disconnected,
    Removed,
}

impl AgentStatus {
    /// Whether the agent is considered alive (able to perform actions).
    #[must_use]
    pub const fn is_alive(self) -> bool {
        matches!(self, Self::Active | Self::Idle)
    }
}

/// Icon source for a persona, supporting system SF Symbols or bundled assets.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PersonaSymbol {
    /// A system SF Symbol identified by name (e.g. `magnifyingglass.circle.fill`).
    SfSymbol { name: String },
    /// An image baked into the app's asset catalog.
    Asset { name: String },
}

/// A predefined agent definition that shapes an agent's role and focus.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentPersona {
    /// Unique slug (e.g. `code-reviewer`, `test-writer`).
    pub identifier: String,
    /// Human-readable display name.
    pub name: String,
    /// Icon for visual identification.
    pub symbol: PersonaSymbol,
    /// What this persona does, shown in detail views.
    pub description: String,
}
