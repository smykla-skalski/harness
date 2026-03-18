mod issue_code;
mod presets;
mod state;
mod tracking;

pub use issue_code::{IssueCode, compute_issue_id};
pub use presets::{FOCUS_PRESETS, FocusPreset, FocusPresetDef};
pub use state::{
    ActiveWorker, AttemptResult, CycleRecord, Issue, IssueAttempt, ObserverState, OpenIssue,
};
pub use tracking::{OccurrenceTracker, ScanState, ToolUseRecord, ToolUseWindow};

use std::fmt;

use serde::{Deserialize, Serialize};

/// Category of an observed issue.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IssueCategory {
    HookFailure,
    CliError,
    ToolError,
    BuildError,
    WorkflowError,
    SkillBehavior,
    SubagentIssue,
    UnexpectedBehavior,
    DataIntegrity,
    NamingError,
    UserFrustration,
}

impl fmt::Display for IssueCategory {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let label = match self {
            Self::HookFailure => "hook_failure",
            Self::CliError => "cli_error",
            Self::ToolError => "tool_error",
            Self::BuildError => "build_error",
            Self::WorkflowError => "workflow_error",
            Self::SkillBehavior => "skill_behavior",
            Self::SubagentIssue => "subagent_issue",
            Self::UnexpectedBehavior => "unexpected_behavior",
            Self::DataIntegrity => "data_integrity",
            Self::NamingError => "naming_error",
            Self::UserFrustration => "user_frustration",
        };
        f.write_str(label)
    }
}

impl IssueCategory {
    /// Parse a category from its `snake_case` string representation.
    #[must_use]
    pub fn from_label(s: &str) -> Option<Self> {
        match s {
            "hook_failure" => Some(Self::HookFailure),
            "cli_error" => Some(Self::CliError),
            "tool_error" => Some(Self::ToolError),
            "build_error" => Some(Self::BuildError),
            "workflow_error" => Some(Self::WorkflowError),
            "skill_behavior" => Some(Self::SkillBehavior),
            "subagent_issue" => Some(Self::SubagentIssue),
            "unexpected_behavior" => Some(Self::UnexpectedBehavior),
            "data_integrity" => Some(Self::DataIntegrity),
            "naming_error" => Some(Self::NamingError),
            "user_frustration" => Some(Self::UserFrustration),
            _ => None,
        }
    }

    /// All category variants for enumeration.
    pub const ALL: &'static [Self] = &[
        Self::HookFailure,
        Self::CliError,
        Self::ToolError,
        Self::BuildError,
        Self::WorkflowError,
        Self::SkillBehavior,
        Self::SubagentIssue,
        Self::UnexpectedBehavior,
        Self::DataIntegrity,
        Self::NamingError,
        Self::UserFrustration,
    ];

    /// Short description for listing.
    #[must_use]
    pub fn description(self) -> &'static str {
        match self {
            Self::HookFailure => "Hook denied or triggered unexpectedly",
            Self::CliError => "Harness CLI returned an error",
            Self::ToolError => "Claude tool usage error",
            Self::BuildError => "Rust build or lint failure",
            Self::WorkflowError => "Workflow state machine error",
            Self::SkillBehavior => "Skill deviated from expected behavior",
            Self::SubagentIssue => "Subagent permission or recovery problem",
            Self::UnexpectedBehavior => "Unexpected agent or environment behavior",
            Self::DataIntegrity => "Data corruption or integrity violation",
            Self::NamingError => "Naming convention violation",
            Self::UserFrustration => "User frustration signal detected",
        }
    }
}

/// Severity level of an observed issue, ordered for filtering.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IssueSeverity {
    Low = 0,
    Medium = 1,
    Critical = 2,
}

impl fmt::Display for IssueSeverity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let label = match self {
            Self::Low => "low",
            Self::Medium => "medium",
            Self::Critical => "critical",
        };
        f.write_str(label)
    }
}

impl IssueSeverity {
    /// Parse a severity from its lowercase string representation.
    #[must_use]
    pub fn from_label(s: &str) -> Option<Self> {
        match s {
            "low" => Some(Self::Low),
            "medium" => Some(Self::Medium),
            "critical" => Some(Self::Critical),
            _ => None,
        }
    }
}

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

// ─── Confidence and FixSafety ──────────────────────────────────────

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

/// Safety level for automated fixes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FixSafety {
    AutoFixSafe,
    AutoFixGuarded,
    TriageRequired,
    AdvisoryOnly,
}

impl fmt::Display for FixSafety {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::AutoFixSafe => "auto_fix_safe",
            Self::AutoFixGuarded => "auto_fix_guarded",
            Self::TriageRequired => "triage_required",
            Self::AdvisoryOnly => "advisory_only",
        })
    }
}

impl FixSafety {
    /// Parse from `snake_case` label.
    #[must_use]
    pub fn from_label(s: &str) -> Option<Self> {
        match s {
            "auto_fix_safe" => Some(Self::AutoFixSafe),
            "auto_fix_guarded" => Some(Self::AutoFixGuarded),
            "triage_required" => Some(Self::TriageRequired),
            "advisory_only" => Some(Self::AdvisoryOnly),
            _ => None,
        }
    }

    /// Whether this safety level allows automated fixes.
    #[must_use]
    pub fn is_fixable(self) -> bool {
        matches!(self, Self::AutoFixSafe | Self::AutoFixGuarded)
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::cognitive_complexity)]

    use super::*;

    #[test]
    fn severity_ordering() {
        assert!(IssueSeverity::Low < IssueSeverity::Medium);
        assert!(IssueSeverity::Medium < IssueSeverity::Critical);
    }

    #[test]
    fn category_display_roundtrip() {
        for cat in IssueCategory::ALL {
            let label = cat.to_string();
            let parsed = IssueCategory::from_label(&label);
            assert_eq!(parsed, Some(*cat), "roundtrip failed for {label}");
        }
    }

    #[test]
    fn severity_display_roundtrip() {
        for sev in [
            IssueSeverity::Low,
            IssueSeverity::Medium,
            IssueSeverity::Critical,
        ] {
            let label = sev.to_string();
            let parsed = IssueSeverity::from_label(&label);
            assert_eq!(parsed, Some(sev), "roundtrip failed for {label}");
        }
    }

    #[test]
    fn issue_serializes_to_json() {
        let issue = Issue {
            issue_id: "abc123def456".into(),
            line: 42,
            code: IssueCode::BuildOrLintFailure,
            category: IssueCategory::BuildError,
            severity: IssueSeverity::Critical,
            confidence: Confidence::High,
            fix_safety: FixSafety::AutoFixSafe,
            summary: "Build failed".into(),
            details: "error[E0308]".into(),
            fingerprint: "build_or_lint_failure".into(),
            source_role: MessageRole::Assistant,
            source_tool: None,
            fix_target: Some("src/main.rs".into()),
            fix_hint: None,
            evidence_excerpt: None,
        };
        let json = serde_json::to_string(&issue).unwrap();
        assert!(json.contains("\"build_error\""));
        assert!(json.contains("\"critical\""));
        assert!(json.contains("\"assistant\""));
        assert!(json.contains("\"abc123def456\""));
        assert!(!json.contains("fix_hint"));
        assert!(!json.contains("source_tool"));
        assert!(!json.contains("evidence_excerpt"));
    }

    #[test]
    fn scan_state_defaults_empty() {
        let state = ScanState::default();
        assert!(state.last_tool_uses.is_empty());
        assert!(state.edit_counts.is_empty());
        assert!(state.seen_issues.is_empty());
        assert!(state.session_start_timestamp.is_none());
        assert!(state.issue_occurrences.is_empty());
        assert!(!state.source_code_edited_without_commit);
        assert!(state.pending_resource_creates.is_empty());
        assert!(state.kubectl_query_targets.is_empty());
        assert!(!state.seen_capture_since_last_group_report);
        assert!(!state.seen_any_group_report);
    }

    #[test]
    fn tool_use_window_evicts_oldest_entry() {
        let mut window = ToolUseWindow::default();
        for index in 0..=ToolUseWindow::LIMIT {
            window.insert(
                format!("tool-{index}"),
                ToolUseRecord {
                    name: "Bash".to_string(),
                    input: serde_json::json!({"command": "echo hello"}),
                },
            );
        }

        assert_eq!(window.len(), ToolUseWindow::LIMIT);
        assert!(!window.contains_key("tool-0"));
        assert!(window.contains_key(&format!("tool-{}", ToolUseWindow::LIMIT)));
    }

    #[test]
    fn message_role_display_roundtrip() {
        for role in [MessageRole::User, MessageRole::Assistant] {
            let label = role.to_string();
            let parsed = MessageRole::from_label(&label);
            assert_eq!(parsed, Some(role), "roundtrip failed for {label}");
        }
    }

    #[test]
    fn message_role_human_alias() {
        assert_eq!(MessageRole::from_label("human"), Some(MessageRole::User));
    }

    #[test]
    fn source_tool_display_roundtrip() {
        let tools = [
            SourceTool::Bash,
            SourceTool::Read,
            SourceTool::Write,
            SourceTool::Edit,
            SourceTool::Agent,
            SourceTool::AskUserQuestion,
        ];
        for tool in tools {
            let label = tool.to_string();
            let parsed = SourceTool::from_label(&label);
            assert_eq!(parsed, Some(tool), "roundtrip failed for {label}");
        }
    }

    #[test]
    fn source_tool_unknown_returns_none() {
        assert_eq!(SourceTool::from_label("Unknown"), None);
    }

    #[test]
    fn category_count() {
        assert_eq!(IssueCategory::ALL.len(), 11);
    }

    #[test]
    fn confidence_display_roundtrip() {
        for conf in [Confidence::High, Confidence::Medium, Confidence::Low] {
            let label = conf.to_string();
            let parsed = Confidence::from_label(&label);
            assert_eq!(parsed, Some(conf), "roundtrip failed for {label}");
        }
    }

    #[test]
    fn fix_safety_display_roundtrip() {
        for safety in [
            FixSafety::AutoFixSafe,
            FixSafety::AutoFixGuarded,
            FixSafety::TriageRequired,
            FixSafety::AdvisoryOnly,
        ] {
            let label = safety.to_string();
            let parsed = FixSafety::from_label(&label);
            assert_eq!(parsed, Some(safety), "roundtrip failed for {label}");
        }
    }

    #[test]
    fn fix_safety_is_fixable() {
        assert!(FixSafety::AutoFixSafe.is_fixable());
        assert!(FixSafety::AutoFixGuarded.is_fixable());
        assert!(!FixSafety::TriageRequired.is_fixable());
        assert!(!FixSafety::AdvisoryOnly.is_fixable());
    }

    #[test]
    fn focus_preset_roundtrip() {
        for (label, expected) in [
            ("harness", FocusPreset::Harness),
            ("skills", FocusPreset::Skills),
            ("all", FocusPreset::All),
        ] {
            assert_eq!(FocusPreset::from_label(label), Some(expected));
        }
        assert_eq!(FocusPreset::from_label("unknown"), None);
    }

    #[test]
    fn focus_preset_categories() {
        assert!(FocusPreset::Harness.categories().is_some());
        assert!(FocusPreset::Skills.categories().is_some());
        assert!(FocusPreset::All.categories().is_none());

        let harness = FocusPreset::Harness.categories().unwrap();
        assert!(harness.contains(&IssueCategory::BuildError));
        assert!(!harness.contains(&IssueCategory::SkillBehavior));
    }

    #[test]
    fn issue_code_display_roundtrip() {
        for code in IssueCode::ALL {
            let label = code.to_string();
            let parsed = IssueCode::from_label(&label);
            assert_eq!(parsed, Some(*code), "roundtrip failed for {label}");
        }
    }

    #[test]
    fn issue_code_all_count() {
        assert_eq!(IssueCode::ALL.len(), 57);
    }

    #[test]
    fn compute_issue_id_deterministic() {
        let id1 = compute_issue_id(&IssueCode::BuildOrLintFailure, "build_or_lint_failure");
        let id2 = compute_issue_id(&IssueCode::BuildOrLintFailure, "build_or_lint_failure");
        assert_eq!(id1, id2);
        assert_eq!(id1.len(), 12);
    }

    #[test]
    fn compute_issue_id_differs_by_code() {
        let id1 = compute_issue_id(&IssueCode::BuildOrLintFailure, "test");
        let id2 = compute_issue_id(&IssueCode::HookDeniedToolCall, "test");
        assert_ne!(id1, id2);
    }

    #[test]
    fn observer_state_default_for_session() {
        let state = ObserverState::default_for_session("test-session");
        assert_eq!(state.schema_version, ObserverState::CURRENT_VERSION);
        assert_eq!(state.session_id, "test-session");
        assert_eq!(state.cursor, 0);
        assert!(state.open_issues.is_empty());
        assert!(state.resolved_issue_ids.is_empty());
        assert!(state.muted_codes.is_empty());
        assert!(state.cycle_history.is_empty());
    }

    #[test]
    fn observer_state_serde_roundtrip() {
        let state = ObserverState::default_for_session("roundtrip-test");
        let json = serde_json::to_string(&state).unwrap();
        let restored: ObserverState = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.session_id, "roundtrip-test");
        assert_eq!(restored.schema_version, state.schema_version);
    }

    #[test]
    fn focus_presets_static() {
        assert_eq!(FOCUS_PRESETS.len(), 3);
        assert_eq!(FOCUS_PRESETS[0].name, "harness");
        assert_eq!(FOCUS_PRESETS[1].name, "skills");
        assert_eq!(FOCUS_PRESETS[2].name, "all");
    }
}
