use std::fmt;

use serde::{Deserialize, Serialize};

/// Category of an observed issue.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
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
    AgentCoordination,
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
            Self::AgentCoordination => "agent_coordination",
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
            "agent_coordination" => Some(Self::AgentCoordination),
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
        Self::AgentCoordination,
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
            Self::AgentCoordination => "Multi-agent coordination issue",
        }
    }
}

/// Severity level of an observed issue, ordered for filtering.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
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

/// Safety level for automated fixes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
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
