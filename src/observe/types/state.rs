use serde::{Deserialize, Serialize};

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

/// Result of a fix attempt for an open issue.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttemptResult {
    Fixed,
    Failed,
    Escalated,
}

/// An open issue tracked across observer cycles.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenIssue {
    pub issue_id: String,
    pub code: IssueCode,
    pub fingerprint: String,
    pub first_seen_line: usize,
    pub last_seen_line: usize,
    pub occurrence_count: usize,
    pub severity: IssueSeverity,
    pub category: IssueCategory,
    pub summary: String,
    pub fix_safety: FixSafety,
    pub evidence_excerpt: Option<String>,
}

/// A fix attempt record.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IssueAttempt {
    pub issue_id: String,
    pub attempt: u32,
    pub result: AttemptResult,
}

/// Durable observer state persisted between cycles.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ObserverState {
    pub schema_version: u32,
    #[serde(default)]
    pub state_version: u64,
    pub session_id: String,
    pub project_hint: Option<String>,
    pub cursor: usize,
    pub last_scan_time: String,
    /// RFC3339 timestamp of the most recent sweep. Read by Decisions-pane
    /// liveness rendering to answer "when did the observer last *do*
    /// anything" without scraping the cycle log.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_sweep_at: Option<String>,
    pub open_issues: Vec<OpenIssue>,
    pub resolved_issue_ids: Vec<String>,
    pub issue_attempts: Vec<IssueAttempt>,
    pub muted_codes: Vec<IssueCode>,
    #[serde(default)]
    pub baseline_issue_ids: Vec<String>,
    #[serde(default)]
    pub active_workers: Vec<ActiveWorker>,
    /// Per-agent observation records for multi-agent sessions.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub agent_sessions: Vec<AgentObserveRecord>,
}

/// Tracks per-agent cursor and metadata in multi-agent observation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentObserveRecord {
    pub agent_id: String,
    pub runtime: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub log_path: Option<String>,
    #[serde(default)]
    pub cursor: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_activity: Option<String>,
}

/// A currently running fix worker tracked in observer state.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActiveWorker {
    pub issue_id: String,
    pub target_file: String,
    pub started_at: String,
    /// Which agent is executing the fix (multi-agent sessions).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
}

impl ObserverState {
    /// Current schema version for observer state files.
    ///
    /// v2 (2026-04-27) drops the `cycle_history` field. Older v1 states are
    /// still readable: serde silently ignores the extra field on
    /// deserialization, and new writes omit it entirely.
    pub const CURRENT_VERSION: u32 = 2;

    /// Create a default state for a new session.
    #[must_use]
    pub fn default_for_session(session_id: impl Into<String>) -> Self {
        Self {
            schema_version: Self::CURRENT_VERSION,
            state_version: 0,
            session_id: session_id.into(),
            project_hint: None,
            cursor: 0,
            last_scan_time: String::new(),
            last_sweep_at: None,
            open_issues: Vec::new(),
            resolved_issue_ids: Vec::new(),
            issue_attempts: Vec::new(),
            muted_codes: Vec::new(),
            baseline_issue_ids: Vec::new(),
            active_workers: Vec::new(),
            agent_sessions: Vec::new(),
        }
    }

    /// Whether the observer state is safe for handoff to another observer.
    /// True when no active workers are running and at least one scan completed.
    #[must_use]
    pub fn handoff_safe(&self) -> bool {
        self.active_workers.is_empty() && !self.last_scan_time.is_empty()
    }

    /// Whether a baseline has been captured.
    #[must_use]
    pub fn has_baseline(&self) -> bool {
        !self.baseline_issue_ids.is_empty()
    }
}
