use std::collections::{HashMap, HashSet};
use std::fmt;

use serde::Serialize;

/// Category of an observed issue.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
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
}

/// Severity level of an observed issue, ordered for filtering.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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

/// A classified issue found in a session log.
#[derive(Debug, Clone, Serialize)]
pub struct Issue {
    pub line: usize,
    pub category: IssueCategory,
    pub severity: IssueSeverity,
    pub summary: String,
    pub details: String,
    pub source_role: MessageRole,
    pub fixable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fix_target: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fix_hint: Option<String>,
}

/// Stable internal identity for a classified issue family.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum IssueCode {
    HookDeniedToolCall,
    HarnessCliErrorOutput,
    ToolUsageErrorOutput,
    BuildOrLintFailure,
    WorkflowStateErrorOutput,
    PodContainerRuntimeFailure,
    AuthFlowTriggered,
    DirectKubectlValidateUsage,
    ShellAliasInterference,
    PayloadWrappedInJsonTags,
    PythonTracebackOutput,
    SuiteDeviationDetected,
    ReleaseKumactlBinaryUsed,
    PythonUsedInBashOutput,
    CorporateClusterContextDetected,
    HarnessHookCodeTriggered,
    ManifestRuntimeFailure,
    HarnessAuthoringCommandFailure,
    NonZeroExitCode,
    SubagentPermissionFailure,
    SubagentManualRecovery,
    ManualPayloadRecovery,
    MissingClaudeSessionId,
    EmptyKubeconfig,
    IncompleteWriterOutput,
    UserFrustrationDetected,
    OldSkillNameUsedInCommand,
    InvalidHarnessSubcommandUsed,
    PythonUsedInBashToolUse,
    UnverifiedRecursiveRemove,
    RawClusterMakeTargetUsed,
    UnauthorizedGitCommitDuringRun,
    ManualKubeconfigConstruction,
    ManualExportConstruction,
    ManualEnvPrefixConstruction,
    ManifestFixPromptShown,
    ValidatorInstallPromptShown,
    RuntimeDeviationPromptShown,
    WrongSkillCrossReference,
    FileEditChurn,
    ShortSkillNameInSkillFile,
    AbsoluteManifestPathUsed,
    DirectManagedFileWrite,
    DirectTaskOutputFileRead,
    HarnessInfrastructureMisconfiguration,
    MissingConnectionOrEnvVar,
}

/// Record of a `tool_use` block, for correlating with `tool_result`.
#[derive(Debug, Clone)]
pub struct ToolUseRecord {
    pub name: String,
    pub input: serde_json::Value,
}

/// Mutable state carried across lines during a scan.
#[derive(Debug, Default)]
pub struct ScanState {
    /// Map `tool_use_id` to the `tool_use` block for correlating with `tool_result`.
    pub last_tool_uses: HashMap<String, ToolUseRecord>,
    /// Track file edit churn: path -> edit count.
    pub edit_counts: HashMap<String, usize>,
    /// Dedup key: (stable issue family, semantic fingerprint).
    pub seen_issues: HashSet<(IssueCode, String)>,
    /// Session start timestamp from the first event.
    pub session_start_timestamp: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn severity_ordering() {
        assert!(IssueSeverity::Low < IssueSeverity::Medium);
        assert!(IssueSeverity::Medium < IssueSeverity::Critical);
    }

    #[test]
    fn category_display_roundtrip() {
        let categories = [
            IssueCategory::HookFailure,
            IssueCategory::CliError,
            IssueCategory::ToolError,
            IssueCategory::BuildError,
            IssueCategory::WorkflowError,
            IssueCategory::SkillBehavior,
            IssueCategory::SubagentIssue,
            IssueCategory::UnexpectedBehavior,
            IssueCategory::DataIntegrity,
            IssueCategory::NamingError,
            IssueCategory::UserFrustration,
        ];
        for cat in categories {
            let label = cat.to_string();
            let parsed = IssueCategory::from_label(&label);
            assert_eq!(parsed, Some(cat), "roundtrip failed for {label}");
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
            line: 42,
            category: IssueCategory::BuildError,
            severity: IssueSeverity::Critical,
            summary: "Build failed".into(),
            details: "error[E0308]".into(),
            source_role: MessageRole::Assistant,
            fixable: true,
            fix_target: Some("src/main.rs".into()),
            fix_hint: None,
        };
        let json = serde_json::to_string(&issue).unwrap();
        assert!(json.contains("\"build_error\""));
        assert!(json.contains("\"critical\""));
        assert!(json.contains("\"assistant\""));
        assert!(!json.contains("fix_hint"));
    }

    #[test]
    fn scan_state_defaults_empty() {
        let state = ScanState::default();
        assert!(state.last_tool_uses.is_empty());
        assert!(state.edit_counts.is_empty());
        assert!(state.seen_issues.is_empty());
        assert!(state.session_start_timestamp.is_none());
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
        assert_eq!(
            [
                IssueCategory::HookFailure,
                IssueCategory::CliError,
                IssueCategory::ToolError,
                IssueCategory::BuildError,
                IssueCategory::WorkflowError,
                IssueCategory::SkillBehavior,
                IssueCategory::SubagentIssue,
                IssueCategory::UnexpectedBehavior,
                IssueCategory::DataIntegrity,
                IssueCategory::NamingError,
                IssueCategory::UserFrustration,
            ]
            .len(),
            11
        );
    }
}
