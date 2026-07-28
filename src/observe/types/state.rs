use serde::Serialize;

use super::{
    Confidence, FixSafety, IssueCategory, IssueCode, IssueSeverity, MessageRole, SourceTool,
};

/// A classified issue found in a session log.
#[derive(Debug, Clone, Serialize)]
pub struct Issue {
    #[serde(rename = "issue_id")]
    pub id: String,
    pub line: usize,
    pub code: IssueCode,
    pub category: IssueCategory,
    pub severity: IssueSeverity,
    pub confidence: Confidence,
    pub fix_safety: FixSafety,
    pub summary: String,
    pub details: String,
    pub fingerprint: String,
    pub source_role: MessageRole,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_tool: Option<SourceTool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fix_target: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fix_hint: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub evidence_excerpt: Option<String>,
}

/// Canonical definition lives in `harness-protocol`: `ObserverState` needs
/// to be a real crate dependency rather than a second copy compiled in
/// through this file's `#[path]` include from the daemon facade. See
/// `harness_protocol::observe`, which also carries the rest of this chain
/// (`OpenIssue`, `IssueAttempt`, `ActiveWorker`, `AgentObserveRecord`) that
/// this file never named directly even before the move.
pub use harness_protocol::observe::{ObserverState, OpenIssue};
#[cfg(test)]
pub use harness_protocol::observe::ActiveWorker;
