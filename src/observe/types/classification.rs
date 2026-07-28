use std::fmt;

use serde::{Deserialize, Serialize};

/// Canonical definition lives in `harness-protocol`: `ObserverState` (in
/// `state.rs`) needs this as a real crate dependency rather than a second
/// copy compiled in through this file's `#[path]` include from the daemon
/// facade. See `harness_protocol::observe`.
pub use harness_protocol::observe::IssueCategory;

/// Canonical definition lives in `harness-protocol`, alongside `IssueCategory`.
pub use harness_protocol::observe::IssueSeverity;

/// Role of the message that produced an issue.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageRole {
    User,
    Assistant,
}

impl fmt::Display for MessageRole {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::User => "user",
            Self::Assistant => "assistant",
        })
    }
}

impl MessageRole {
    /// Parse a role from its JSON string representation.
    #[must_use]
    pub fn from_label(s: &str) -> Option<Self> {
        match s {
            "user" | "human" => Some(Self::User),
            "assistant" => Some(Self::Assistant),
            _ => None,
        }
    }
}

/// Tool that produced a piece of text (resolved from `tool_use` correlation).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum SourceTool {
    Bash,
    Read,
    Write,
    Edit,
    Agent,
    AskUserQuestion,
}

impl fmt::Display for SourceTool {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Bash => "Bash",
            Self::Read => "Read",
            Self::Write => "Write",
            Self::Edit => "Edit",
            Self::Agent => "Agent",
            Self::AskUserQuestion => "AskUserQuestion",
        })
    }
}

impl SourceTool {
    /// Parse a tool name from its string representation.
    #[must_use]
    pub fn from_label(s: &str) -> Option<Self> {
        match s {
            "Bash" => Some(Self::Bash),
            "Read" => Some(Self::Read),
            "Write" => Some(Self::Write),
            "Edit" => Some(Self::Edit),
            "Agent" => Some(Self::Agent),
            "AskUserQuestion" => Some(Self::AskUserQuestion),
            _ => None,
        }
    }
}

/// Confidence level of a classification.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Confidence {
    High,
    Medium,
    Low,
}

impl fmt::Display for Confidence {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::High => "high",
            Self::Medium => "medium",
            Self::Low => "low",
        })
    }
}

impl Confidence {
    /// Parse from lowercase label.
    #[must_use]
    pub fn from_label(s: &str) -> Option<Self> {
        match s {
            "high" => Some(Self::High),
            "medium" => Some(Self::Medium),
            "low" => Some(Self::Low),
            _ => None,
        }
    }
}

/// Canonical definition lives in `harness-protocol`, alongside `IssueCategory`.
pub use harness_protocol::observe::FixSafety;
