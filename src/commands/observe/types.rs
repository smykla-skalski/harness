use std::collections::{HashMap, HashSet, VecDeque};
use std::fmt;
use std::ops::Index;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

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

// ─── Focus presets ─────────────────────────────────────────────────

/// Pre-defined category filter presets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FocusPreset {
    Harness,
    Skills,
    All,
}

/// Static metadata for a focus preset.
pub struct FocusPresetDef {
    pub name: &'static str,
    pub description: &'static str,
    pub categories: Option<&'static [IssueCategory]>,
}

static HARNESS_CATEGORIES: &[IssueCategory] = &[
    IssueCategory::BuildError,
    IssueCategory::CliError,
    IssueCategory::WorkflowError,
    IssueCategory::DataIntegrity,
];

static SKILLS_CATEGORIES: &[IssueCategory] = &[
    IssueCategory::SkillBehavior,
    IssueCategory::HookFailure,
    IssueCategory::NamingError,
    IssueCategory::SubagentIssue,
];

pub static FOCUS_PRESETS: &[FocusPresetDef] = &[
    FocusPresetDef {
        name: "harness",
        description: "Build, CLI, workflow, and data integrity issues",
        categories: Some(HARNESS_CATEGORIES),
    },
    FocusPresetDef {
        name: "skills",
        description: "Skill behavior, hooks, naming, and subagent issues",
        categories: Some(SKILLS_CATEGORIES),
    },
    FocusPresetDef {
        name: "all",
        description: "All categories (no filter)",
        categories: None,
    },
];

impl FocusPreset {
    /// Parse from label string.
    #[must_use]
    pub fn from_label(s: &str) -> Option<Self> {
        match s {
            "harness" => Some(Self::Harness),
            "skills" => Some(Self::Skills),
            "all" => Some(Self::All),
            _ => None,
        }
    }

    /// Category filter for this preset. `None` means no filter (all categories).
    #[must_use]
    pub fn categories(self) -> Option<Vec<IssueCategory>> {
        match self {
            Self::Harness => Some(HARNESS_CATEGORIES.to_vec()),
            Self::Skills => Some(SKILLS_CATEGORIES.to_vec()),
            Self::All => None,
        }
    }
}

// ─── Issue codes ───────────────────────────────────────────────────

/// Stable internal identity for a classified issue family.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
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
    ManifestCreatedDuringRun,
    DirectTaskOutputFileRead,
    HarnessInfrastructureMisconfiguration,
    MissingConnectionOrEnvVar,
    SleepPrefixBeforeHarnessCommand,
    JqErrorInCommandOutput,
    CloseoutVerdictPending,
    RunnerStateEventNotSupported,
    RunnerStateMachineStale,
    UncommittedSourceCodeEdit,
    ResourceNotCleanedUpBeforeGroupEnd,
    RepeatedKubectlQueryForSameResource,
    GroupReportedWithoutCapture,
    VerificationOutputTruncated,
}

impl fmt::Display for IssueCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let label = match self {
            Self::HookDeniedToolCall => "hook_denied_tool_call",
            Self::HarnessCliErrorOutput => "harness_cli_error_output",
            Self::ToolUsageErrorOutput => "tool_usage_error_output",
            Self::BuildOrLintFailure => "build_or_lint_failure",
            Self::WorkflowStateErrorOutput => "workflow_state_error_output",
            Self::PodContainerRuntimeFailure => "pod_container_runtime_failure",
            Self::AuthFlowTriggered => "auth_flow_triggered",
            Self::DirectKubectlValidateUsage => "direct_kubectl_validate_usage",
            Self::ShellAliasInterference => "shell_alias_interference",
            Self::PayloadWrappedInJsonTags => "payload_wrapped_in_json_tags",
            Self::PythonTracebackOutput => "python_traceback_output",
            Self::SuiteDeviationDetected => "suite_deviation_detected",
            Self::ReleaseKumactlBinaryUsed => "release_kumactl_binary_used",
            Self::PythonUsedInBashOutput => "python_used_in_bash_output",
            Self::CorporateClusterContextDetected => "corporate_cluster_context_detected",
            Self::HarnessHookCodeTriggered => "harness_hook_code_triggered",
            Self::ManifestRuntimeFailure => "manifest_runtime_failure",
            Self::HarnessAuthoringCommandFailure => "harness_authoring_command_failure",
            Self::NonZeroExitCode => "non_zero_exit_code",
            Self::SubagentPermissionFailure => "subagent_permission_failure",
            Self::SubagentManualRecovery => "subagent_manual_recovery",
            Self::ManualPayloadRecovery => "manual_payload_recovery",
            Self::MissingClaudeSessionId => "missing_claude_session_id",
            Self::EmptyKubeconfig => "empty_kubeconfig",
            Self::IncompleteWriterOutput => "incomplete_writer_output",
            Self::UserFrustrationDetected => "user_frustration_detected",
            Self::OldSkillNameUsedInCommand => "old_skill_name_used_in_command",
            Self::InvalidHarnessSubcommandUsed => "invalid_harness_subcommand_used",
            Self::PythonUsedInBashToolUse => "python_used_in_bash_tool_use",
            Self::UnverifiedRecursiveRemove => "unverified_recursive_remove",
            Self::RawClusterMakeTargetUsed => "raw_cluster_make_target_used",
            Self::UnauthorizedGitCommitDuringRun => "unauthorized_git_commit_during_run",
            Self::ManualKubeconfigConstruction => "manual_kubeconfig_construction",
            Self::ManualExportConstruction => "manual_export_construction",
            Self::ManualEnvPrefixConstruction => "manual_env_prefix_construction",
            Self::ManifestFixPromptShown => "manifest_fix_prompt_shown",
            Self::ValidatorInstallPromptShown => "validator_install_prompt_shown",
            Self::RuntimeDeviationPromptShown => "runtime_deviation_prompt_shown",
            Self::WrongSkillCrossReference => "wrong_skill_cross_reference",
            Self::FileEditChurn => "file_edit_churn",
            Self::ShortSkillNameInSkillFile => "short_skill_name_in_skill_file",
            Self::AbsoluteManifestPathUsed => "absolute_manifest_path_used",
            Self::DirectManagedFileWrite => "direct_managed_file_write",
            Self::ManifestCreatedDuringRun => "manifest_created_during_run",
            Self::DirectTaskOutputFileRead => "direct_task_output_file_read",
            Self::HarnessInfrastructureMisconfiguration => {
                "harness_infrastructure_misconfiguration"
            }
            Self::MissingConnectionOrEnvVar => "missing_connection_or_env_var",
            Self::SleepPrefixBeforeHarnessCommand => "sleep_prefix_before_harness_command",
            Self::JqErrorInCommandOutput => "jq_error_in_command_output",
            Self::CloseoutVerdictPending => "closeout_verdict_pending",
            Self::RunnerStateEventNotSupported => "runner_state_event_not_supported",
            Self::RunnerStateMachineStale => "runner_state_machine_stale",
            Self::UncommittedSourceCodeEdit => "uncommitted_source_code_edit",
            Self::ResourceNotCleanedUpBeforeGroupEnd => "resource_not_cleaned_up_before_group_end",
            Self::RepeatedKubectlQueryForSameResource => "repeated_kubectl_query_for_same_resource",
            Self::GroupReportedWithoutCapture => "group_reported_without_capture",
            Self::VerificationOutputTruncated => "verification_output_truncated",
        };
        f.write_str(label)
    }
}

impl IssueCode {
    /// Parse from `snake_case` label.
    #[must_use]
    pub fn from_label(s: &str) -> Option<Self> {
        match s {
            "hook_denied_tool_call" => Some(Self::HookDeniedToolCall),
            "harness_cli_error_output" => Some(Self::HarnessCliErrorOutput),
            "tool_usage_error_output" => Some(Self::ToolUsageErrorOutput),
            "build_or_lint_failure" => Some(Self::BuildOrLintFailure),
            "workflow_state_error_output" => Some(Self::WorkflowStateErrorOutput),
            "pod_container_runtime_failure" => Some(Self::PodContainerRuntimeFailure),
            "auth_flow_triggered" => Some(Self::AuthFlowTriggered),
            "direct_kubectl_validate_usage" => Some(Self::DirectKubectlValidateUsage),
            "shell_alias_interference" => Some(Self::ShellAliasInterference),
            "payload_wrapped_in_json_tags" => Some(Self::PayloadWrappedInJsonTags),
            "python_traceback_output" => Some(Self::PythonTracebackOutput),
            "suite_deviation_detected" => Some(Self::SuiteDeviationDetected),
            "release_kumactl_binary_used" => Some(Self::ReleaseKumactlBinaryUsed),
            "python_used_in_bash_output" => Some(Self::PythonUsedInBashOutput),
            "corporate_cluster_context_detected" => Some(Self::CorporateClusterContextDetected),
            "harness_hook_code_triggered" => Some(Self::HarnessHookCodeTriggered),
            "manifest_runtime_failure" => Some(Self::ManifestRuntimeFailure),
            "harness_authoring_command_failure" => Some(Self::HarnessAuthoringCommandFailure),
            "non_zero_exit_code" => Some(Self::NonZeroExitCode),
            "subagent_permission_failure" => Some(Self::SubagentPermissionFailure),
            "subagent_manual_recovery" => Some(Self::SubagentManualRecovery),
            "manual_payload_recovery" => Some(Self::ManualPayloadRecovery),
            "missing_claude_session_id" => Some(Self::MissingClaudeSessionId),
            "empty_kubeconfig" => Some(Self::EmptyKubeconfig),
            "incomplete_writer_output" => Some(Self::IncompleteWriterOutput),
            "user_frustration_detected" => Some(Self::UserFrustrationDetected),
            "old_skill_name_used_in_command" => Some(Self::OldSkillNameUsedInCommand),
            "invalid_harness_subcommand_used" => Some(Self::InvalidHarnessSubcommandUsed),
            "python_used_in_bash_tool_use" => Some(Self::PythonUsedInBashToolUse),
            "unverified_recursive_remove" => Some(Self::UnverifiedRecursiveRemove),
            "raw_cluster_make_target_used" => Some(Self::RawClusterMakeTargetUsed),
            "unauthorized_git_commit_during_run" => Some(Self::UnauthorizedGitCommitDuringRun),
            "manual_kubeconfig_construction" => Some(Self::ManualKubeconfigConstruction),
            "manual_export_construction" => Some(Self::ManualExportConstruction),
            "manual_env_prefix_construction" => Some(Self::ManualEnvPrefixConstruction),
            "manifest_fix_prompt_shown" => Some(Self::ManifestFixPromptShown),
            "validator_install_prompt_shown" => Some(Self::ValidatorInstallPromptShown),
            "runtime_deviation_prompt_shown" => Some(Self::RuntimeDeviationPromptShown),
            "wrong_skill_cross_reference" => Some(Self::WrongSkillCrossReference),
            "file_edit_churn" => Some(Self::FileEditChurn),
            "short_skill_name_in_skill_file" => Some(Self::ShortSkillNameInSkillFile),
            "absolute_manifest_path_used" => Some(Self::AbsoluteManifestPathUsed),
            "direct_managed_file_write" => Some(Self::DirectManagedFileWrite),
            "manifest_created_during_run" => Some(Self::ManifestCreatedDuringRun),
            "direct_task_output_file_read" => Some(Self::DirectTaskOutputFileRead),
            "harness_infrastructure_misconfiguration" => {
                Some(Self::HarnessInfrastructureMisconfiguration)
            }
            "missing_connection_or_env_var" => Some(Self::MissingConnectionOrEnvVar),
            "sleep_prefix_before_harness_command" => Some(Self::SleepPrefixBeforeHarnessCommand),
            "jq_error_in_command_output" => Some(Self::JqErrorInCommandOutput),
            "closeout_verdict_pending" => Some(Self::CloseoutVerdictPending),
            "runner_state_event_not_supported" => Some(Self::RunnerStateEventNotSupported),
            "runner_state_machine_stale" => Some(Self::RunnerStateMachineStale),
            "uncommitted_source_code_edit" => Some(Self::UncommittedSourceCodeEdit),
            "resource_not_cleaned_up_before_group_end" => {
                Some(Self::ResourceNotCleanedUpBeforeGroupEnd)
            }
            "repeated_kubectl_query_for_same_resource" => {
                Some(Self::RepeatedKubectlQueryForSameResource)
            }
            "group_reported_without_capture" => Some(Self::GroupReportedWithoutCapture),
            "verification_output_truncated" => Some(Self::VerificationOutputTruncated),
            _ => None,
        }
    }

    /// All code variants for enumeration.
    pub const ALL: &'static [Self] = &[
        Self::HookDeniedToolCall,
        Self::HarnessCliErrorOutput,
        Self::ToolUsageErrorOutput,
        Self::BuildOrLintFailure,
        Self::WorkflowStateErrorOutput,
        Self::PodContainerRuntimeFailure,
        Self::AuthFlowTriggered,
        Self::DirectKubectlValidateUsage,
        Self::ShellAliasInterference,
        Self::PayloadWrappedInJsonTags,
        Self::PythonTracebackOutput,
        Self::SuiteDeviationDetected,
        Self::ReleaseKumactlBinaryUsed,
        Self::PythonUsedInBashOutput,
        Self::CorporateClusterContextDetected,
        Self::HarnessHookCodeTriggered,
        Self::ManifestRuntimeFailure,
        Self::HarnessAuthoringCommandFailure,
        Self::NonZeroExitCode,
        Self::SubagentPermissionFailure,
        Self::SubagentManualRecovery,
        Self::ManualPayloadRecovery,
        Self::MissingClaudeSessionId,
        Self::EmptyKubeconfig,
        Self::IncompleteWriterOutput,
        Self::UserFrustrationDetected,
        Self::OldSkillNameUsedInCommand,
        Self::InvalidHarnessSubcommandUsed,
        Self::PythonUsedInBashToolUse,
        Self::UnverifiedRecursiveRemove,
        Self::RawClusterMakeTargetUsed,
        Self::UnauthorizedGitCommitDuringRun,
        Self::ManualKubeconfigConstruction,
        Self::ManualExportConstruction,
        Self::ManualEnvPrefixConstruction,
        Self::ManifestFixPromptShown,
        Self::ValidatorInstallPromptShown,
        Self::RuntimeDeviationPromptShown,
        Self::WrongSkillCrossReference,
        Self::FileEditChurn,
        Self::ShortSkillNameInSkillFile,
        Self::AbsoluteManifestPathUsed,
        Self::DirectManagedFileWrite,
        Self::ManifestCreatedDuringRun,
        Self::DirectTaskOutputFileRead,
        Self::HarnessInfrastructureMisconfiguration,
        Self::MissingConnectionOrEnvVar,
        Self::SleepPrefixBeforeHarnessCommand,
        Self::JqErrorInCommandOutput,
        Self::CloseoutVerdictPending,
        Self::RunnerStateEventNotSupported,
        Self::RunnerStateMachineStale,
        Self::UncommittedSourceCodeEdit,
        Self::ResourceNotCleanedUpBeforeGroupEnd,
        Self::RepeatedKubectlQueryForSameResource,
        Self::GroupReportedWithoutCapture,
        Self::VerificationOutputTruncated,
    ];
}

/// Compute a stable 12-char hex issue identity from code + fingerprint.
#[must_use]
pub fn compute_issue_id(code: &IssueCode, fingerprint: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(code.to_string().as_bytes());
    hasher.update(b"\0");
    hasher.update(fingerprint.as_bytes());
    let digest = hasher.finalize();
    hex::encode(&digest[..6])
}

// ─── Issue struct ──────────────────────────────────────────────────

/// A classified issue found in a session log.
#[derive(Debug, Clone, Serialize)]
pub struct Issue {
    pub issue_id: String,
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

// ─── Observer state ────────────────────────────────────────────────

/// Result of a fix attempt for an open issue.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttemptResult {
    Fixed,
    Failed,
    Escalated,
}

/// Record of a single observer cycle.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CycleRecord {
    pub timestamp: String,
    pub from_line: usize,
    pub to_line: usize,
    pub new_issues: usize,
    pub resolved: usize,
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
    pub session_id: String,
    pub project_hint: Option<String>,
    pub cursor: usize,
    pub last_scan_time: String,
    pub open_issues: Vec<OpenIssue>,
    pub resolved_issue_ids: Vec<String>,
    pub issue_attempts: Vec<IssueAttempt>,
    pub muted_codes: Vec<IssueCode>,
    pub cycle_history: Vec<CycleRecord>,
    #[serde(default)]
    pub baseline_issue_ids: Vec<String>,
    #[serde(default)]
    pub active_workers: Vec<ActiveWorker>,
}

/// A currently running fix worker tracked in observer state.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActiveWorker {
    pub issue_id: String,
    pub target_file: String,
    pub started_at: String,
}

impl ObserverState {
    /// Current schema version for observer state files.
    pub const CURRENT_VERSION: u32 = 1;

    /// Create a default state for a new session.
    #[must_use]
    pub fn default_for_session(session_id: impl Into<String>) -> Self {
        Self {
            schema_version: Self::CURRENT_VERSION,
            session_id: session_id.into(),
            project_hint: None,
            cursor: 0,
            last_scan_time: String::new(),
            open_issues: Vec::new(),
            resolved_issue_ids: Vec::new(),
            issue_attempts: Vec::new(),
            muted_codes: Vec::new(),
            cycle_history: Vec::new(),
            baseline_issue_ids: Vec::new(),
            active_workers: Vec::new(),
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

// ─── Occurrence tracking ───────────────────────────────────────────

/// Tracks occurrences of a deduplicated issue family.
#[derive(Debug, Clone)]
pub struct OccurrenceTracker {
    pub count: usize,
    pub first_seen_line: usize,
    pub last_seen_line: usize,
}

/// Record of a `tool_use` block, for correlating with `tool_result`.
#[derive(Debug, Clone)]
pub struct ToolUseRecord {
    pub name: String,
    pub input: serde_json::Value,
}

/// Ordered bounded window of recent `tool_use` blocks.
#[derive(Debug, Clone, Default)]
pub struct ToolUseWindow {
    order: VecDeque<String>,
    records: HashMap<String, ToolUseRecord>,
}

impl ToolUseWindow {
    const LIMIT: usize = 100;

    pub fn insert(&mut self, tool_use_id: String, record: ToolUseRecord) {
        if self.records.contains_key(&tool_use_id) {
            self.order.retain(|existing| existing != &tool_use_id);
        }
        self.order.push_back(tool_use_id.clone());
        self.records.insert(tool_use_id, record);

        while self.order.len() > Self::LIMIT {
            if let Some(oldest) = self.order.pop_front() {
                self.records.remove(&oldest);
            }
        }
    }

    #[must_use]
    pub fn get(&self, tool_use_id: &str) -> Option<&ToolUseRecord> {
        self.records.get(tool_use_id)
    }

    #[must_use]
    pub fn contains_key(&self, tool_use_id: &str) -> bool {
        self.records.contains_key(tool_use_id)
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.records.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }
}

impl Index<&str> for ToolUseWindow {
    type Output = ToolUseRecord;

    fn index(&self, index: &str) -> &Self::Output {
        &self.records[index]
    }
}

/// Mutable state carried across lines during a scan.
#[derive(Debug, Default)]
pub struct ScanState {
    /// Map `tool_use_id` to the `tool_use` block for correlating with `tool_result`.
    pub last_tool_uses: ToolUseWindow,
    /// Track file edit churn: path -> edit count.
    pub edit_counts: HashMap<String, usize>,
    /// Dedup key: (stable issue family, semantic fingerprint).
    pub seen_issues: HashSet<(IssueCode, String)>,
    /// Session start timestamp from the first event.
    pub session_start_timestamp: Option<String>,
    /// Occurrence tracking: (code, fingerprint) -> tracker.
    pub issue_occurrences: HashMap<(IssueCode, String), OccurrenceTracker>,
    /// Set when a source code file is edited via Write/Edit without a
    /// subsequent `git commit`. Cleared on commit detection.
    pub source_code_edited_without_commit: bool,
    /// Resources created via `harness apply` or `harness delete` in the
    /// current group. Entries are `(resource_kind, resource_name)` pairs
    /// extracted from `--manifest` path segments. Cleared when
    /// `harness report group` is called after checking for missing deletes.
    pub pending_resource_creates: HashSet<String>,
    /// Recent kubectl get/describe targets with their line numbers.
    /// Used to detect piecemeal queries against the same resource.
    /// Each entry is `(normalized_target, line_number)`.
    pub kubectl_query_targets: VecDeque<(String, usize)>,
    /// Whether `harness capture` was seen since the last `harness report group`.
    /// Set to `true` on capture, reset to `false` on group report. Starts
    /// `true` so the very first group does not trigger a false positive.
    pub seen_capture_since_last_group_report: bool,
    /// Whether at least one `harness report group` has been seen. Used to
    /// distinguish the first group (no preceding capture obligation) from
    /// subsequent groups.
    pub seen_any_group_report: bool,
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
