use clap::ValueEnum;
use serde::{Deserialize, Serialize, de};

use crate::agents::kind::{DisconnectReason, RuntimeKind};
use crate::agents::runtime::RuntimeCapabilities;

/// An agent registered in a multi-agent session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentRegistration {
    pub agent_id: String,
    /// Human-readable display name.
    pub name: String,
    /// Tagged runtime identity. See [`RuntimeKind`] for the paradigm-shift
    /// note on TUI-wrapper → agent-host.
    pub runtime: RuntimeKind,
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
    /// Task this agent currently holds.
    ///
    /// Set eagerly by `start_task_for_agent` when a task-start signal is sent
    /// so subsequent drops on a different task are queued correctly. The
    /// signal-ack handler reaffirms the same value when the worker actually
    /// starts work, and `clear_agent_current_task` clears it on drop, ack
    /// rejection, signal expiry, and disconnect.
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
///
/// `Disconnected` carries the reason and the tail of the agent's stderr (when
/// available) so the UI can compute restart eligibility from the reason and
/// surface the last few lines without an extra round-trip.
///
/// Wire shape stays backwards-compatible with pre-Chunk-2 storage: unit
/// variants serialise as bare snake-case strings (`"active"`, `"idle"`,
/// `"awaiting_review"`, `"removed"`); `Disconnected` is the only shape that
/// must be an object (`{ "state": "disconnected", "reason": ..., "stderr_tail": ... }`).
/// The legacy bare-string `"disconnected"` deserialises into
/// `Disconnected { reason: Unknown, stderr_tail: None }`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AgentStatus {
    Active,
    /// Agent is alive but has not used tools recently.
    Idle,
    /// Agent submitted a task for review and is holding for reviewer verdict.
    AwaitingReview,
    Disconnected {
        reason: DisconnectReason,
        stderr_tail: Option<String>,
    },
    Removed,
}

// --- AgentStatus Serde -----------------------------------------------------
//
// Dual on-disk shape, deliberately. The rule:
//
//  - Unit variants (`Active`, `Idle`, `AwaitingReview`, `Removed`) serialise
//    as bare snake_case strings. They carry no payload and the bare-string
//    form is the form every pre-Chunk-2 state file already has on disk; the
//    v10→v11 migrator only rewrites `"disconnected"` because it is the only
//    variant that gained data. Keeping the bare-string form here means the
//    migrator does the minimum work and a state file written by this daemon
//    does not gratuitously diverge from the pre-Chunk-2 wire format.
//
//  - `Disconnected` serialises as `{ "state": "disconnected", "reason": ...,
//    "stderr_tail": ... }`. It is the only variant with a payload; the
//    object form is the only honest place to put it.
//
// On the read path the deserializer accepts both shapes (see
// `AgentStatusOnDisk` below) so a forward-rolled state file written by a
// daemon that emits the tagged form for unit variants too — should that
// ever happen — still parses. The legacy bare-string `"disconnected"` reads
// as `Disconnected { reason: Unknown, stderr_tail: None }` so the migrator
// is belt-and-braces, not a hard prerequisite.
//
// If a future change adds a payload to a unit variant, follow the
// `Disconnected` precedent: bump it to a struct variant, emit the tagged
// shape only for that variant, and add a one-step migrator. Do not collapse
// every variant to the tagged form — that would force every pre-Chunk-2
// state file through a migrator that had no other reason to exist.
impl Serialize for AgentStatus {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        match self {
            Self::Active => serializer.serialize_str("active"),
            Self::Idle => serializer.serialize_str("idle"),
            Self::AwaitingReview => serializer.serialize_str("awaiting_review"),
            Self::Removed => serializer.serialize_str("removed"),
            Self::Disconnected {
                reason,
                stderr_tail,
            } => {
                let mut state = serializer
                    .serialize_struct("AgentStatus", if stderr_tail.is_some() { 3 } else { 2 })?;
                state.serialize_field("state", "disconnected")?;
                state.serialize_field("reason", reason)?;
                if let Some(tail) = stderr_tail {
                    state.serialize_field("stderr_tail", tail)?;
                }
                state.end()
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(untagged)]
enum AgentStatusOnDisk {
    Bare(String),
    Tagged {
        state: String,
        #[serde(default)]
        reason: Option<DisconnectReason>,
        #[serde(default)]
        stderr_tail: Option<String>,
    },
}

impl<'de> Deserialize<'de> for AgentStatus {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let parse_bare = |state: &str| -> Result<Self, D::Error> {
            match state {
                "active" => Ok(Self::Active),
                "idle" => Ok(Self::Idle),
                "awaiting_review" => Ok(Self::AwaitingReview),
                "removed" => Ok(Self::Removed),
                "disconnected" => Ok(Self::Disconnected {
                    reason: DisconnectReason::default(),
                    stderr_tail: None,
                }),
                other => Err(de::Error::custom(format!("unknown agent status '{other}'"))),
            }
        };
        match AgentStatusOnDisk::deserialize(deserializer)? {
            AgentStatusOnDisk::Bare(state) => parse_bare(&state),
            AgentStatusOnDisk::Tagged {
                state,
                reason,
                stderr_tail,
            } => {
                if state == "disconnected" {
                    Ok(Self::Disconnected {
                        reason: reason.unwrap_or_default(),
                        stderr_tail,
                    })
                } else {
                    parse_bare(&state)
                }
            }
        }
    }
}

impl AgentStatus {
    /// Whether the agent is considered alive (able to perform actions).
    #[must_use]
    pub const fn is_alive(&self) -> bool {
        matches!(self, Self::Active | Self::Idle | Self::AwaitingReview)
    }

    /// Whether the agent is eligible to accept a new task assignment.
    ///
    /// Agents awaiting reviewer feedback must not pick up new work until the
    /// review round closes.
    #[must_use]
    pub const fn accepts_assignment(&self) -> bool {
        matches!(self, Self::Active | Self::Idle)
    }

    /// Whether this status is the `Disconnected` variant (any reason).
    #[must_use]
    pub const fn is_disconnected(&self) -> bool {
        matches!(self, Self::Disconnected { .. })
    }

    /// Whether this status is `Removed`.
    #[must_use]
    pub const fn is_removed(&self) -> bool {
        matches!(self, Self::Removed)
    }

    /// Build a `Disconnected` status with a specific reason and no stderr.
    #[must_use]
    pub const fn disconnected(reason: DisconnectReason) -> Self {
        Self::Disconnected {
            reason,
            stderr_tail: None,
        }
    }

    /// Build a `Disconnected { reason: Unknown, .. }` status.
    ///
    /// TRANSITIONAL — TODO(acp-chunk-3): every call site that builds this
    /// should be supplying a precise [`DisconnectReason`] instead. Chunk 3
    /// of `~/.claude/plans/full-support-of-acp-enchanted-church.md`
    /// introduces the ACP runtime adapter which is the producer side of
    /// `ProcessExited`, `StdioClosed`, `OomKilled`, etc.; once that lands
    /// every disconnect path must name its reason and this constructor
    /// should be removed (with `#[deprecated]` first, callers migrated,
    /// then deletion). Do not reach for this from new call sites — they
    /// will get held over in review.
    #[must_use]
    pub fn disconnected_unknown() -> Self {
        Self::disconnected(DisconnectReason::default())
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
