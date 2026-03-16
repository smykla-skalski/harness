use std::collections::HashSet;

use super::emitter::{Guidance, IssueBlueprint, IssueEmitter};
use crate::commands::observe::patterns;
use crate::commands::observe::types::{
    Issue, IssueCategory, IssueCode, IssueSeverity, MessageRole, ScanState, SourceTool,
};

/// Filter on message role.
#[derive(Clone, Copy)]
pub(super) enum RoleFilter {
    /// No filter - any role matches.
    Any,
    /// Must match this exact role.
    Exact(MessageRole),
}

/// Filter on source tool.
#[derive(Clone, Copy)]
pub(super) enum ToolFilter {
    /// No filter - any source tool (including None).
    Any,
    /// Must match this exact source tool.
    Exact(SourceTool),
    /// Source tool must be None (plain text, not tool output).
    Absent,
}

/// How to match patterns against lowercased text.
#[derive(Clone, Copy)]
pub(super) enum MatchMode {
    /// Stop at the first matching pattern; include it in summary if requested.
    FirstMatch,
    /// Check if any pattern matches (no specific pattern in summary).
    Any,
}

/// How the dedup fingerprint should be derived for a rule hit.
#[derive(Clone, Copy)]
pub(super) enum FingerprintMode {
    /// One semantic issue for the whole rule.
    Static,
    /// Different matched patterns should be emitted independently.
    MatchedPattern,
}

/// Internal guidance for static rules.
#[derive(Clone, Copy)]
pub(super) enum RuleGuidance {
    None,
    Advisory {
        target: Option<&'static str>,
        hint: &'static str,
    },
    Fix {
        target: Option<&'static str>,
        hint: Option<&'static str>,
    },
}

impl RuleGuidance {
    fn into_guidance(self) -> Guidance {
        match self {
            Self::None => Guidance::None,
            Self::Advisory { target, hint } => {
                if let Some(target) = target {
                    Guidance::advisory_target(target, hint)
                } else {
                    Guidance::advisory(hint)
                }
            }
            Self::Fix { target, hint } => match (target, hint) {
                (Some(target), Some(hint)) => Guidance::fix_target_hint(target, hint),
                (Some(target), None) => Guidance::fix_target(target),
                (None, Some(hint)) => Guidance::fix_hint(hint),
                (None, None) => Guidance::fix(),
            },
        }
    }
}

/// A declarative text classification rule. Rules are evaluated in order;
/// each matched rule adds its category to the matched set so later rules
/// can skip via `skip_if_matched`.
pub(super) struct TextRule {
    pub code: IssueCode,
    pub role_filter: RoleFilter,
    pub source_tool_filter: ToolFilter,
    pub extra_guard: Option<&'static str>,
    pub patterns: &'static [&'static str],
    pub match_mode: MatchMode,
    pub fingerprint_mode: FingerprintMode,
    pub category: IssueCategory,
    pub severity: IssueSeverity,
    pub summary: &'static str,
    pub include_pattern: bool,
    pub guidance: RuleGuidance,
    pub skip_if_matched: &'static [IssueCategory],
}

pub(super) static TEXT_RULES: &[TextRule] = &[
    // Hook denials
    TextRule {
        code: IssueCode::HookDeniedToolCall,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Any,
        extra_guard: None,
        patterns: &["denied this tool", "blocked by hook"],
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::HookFailure,
        severity: IssueSeverity::Medium,
        summary: "Hook denied a tool call",
        include_pattern: false,
        guidance: RuleGuidance::None,
        skip_if_matched: &[],
    },
    // CLI errors (marks CliError so build_errors can skip)
    TextRule {
        code: IssueCode::HarnessCliErrorOutput,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact(SourceTool::Bash),
        extra_guard: Some("harness"),
        patterns: patterns::CLI_ERROR_PATTERNS,
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::MatchedPattern,
        category: IssueCategory::CliError,
        severity: IssueSeverity::Medium,
        summary: "Harness CLI error: ",
        include_pattern: true,
        guidance: RuleGuidance::Fix {
            target: Some("cli.rs"),
            hint: None,
        },
        skip_if_matched: &[],
    },
    // Tool errors
    TextRule {
        code: IssueCode::ToolUsageErrorOutput,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Any,
        extra_guard: None,
        patterns: patterns::TOOL_ERROR_PATTERNS,
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::MatchedPattern,
        category: IssueCategory::ToolError,
        severity: IssueSeverity::Low,
        summary: "Tool usage error: ",
        include_pattern: true,
        guidance: RuleGuidance::Advisory {
            target: None,
            hint: "Model behavior - read before edit",
        },
        skip_if_matched: &[],
    },
    // Build errors (skip when CLI error already matched)
    TextRule {
        code: IssueCode::BuildOrLintFailure,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact(SourceTool::Bash),
        extra_guard: None,
        patterns: patterns::BUILD_ERROR_PATTERNS,
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::BuildError,
        severity: IssueSeverity::Critical,
        summary: "Build or lint failure",
        include_pattern: false,
        guidance: RuleGuidance::Fix {
            target: None,
            hint: Some("Fix the Rust code causing the failure"),
        },
        skip_if_matched: &[IssueCategory::CliError],
    },
    // Workflow errors
    TextRule {
        code: IssueCode::WorkflowStateErrorOutput,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact(SourceTool::Bash),
        extra_guard: None,
        patterns: patterns::WORKFLOW_ERROR_PATTERNS,
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::MatchedPattern,
        category: IssueCategory::WorkflowError,
        severity: IssueSeverity::Medium,
        summary: "Workflow state error: ",
        include_pattern: true,
        guidance: RuleGuidance::Fix {
            target: None,
            hint: Some("Check workflow state machine logic"),
        },
        skip_if_matched: &[],
    },
    // Pod / container failures
    TextRule {
        code: IssueCode::PodContainerRuntimeFailure,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact(SourceTool::Bash),
        extra_guard: None,
        patterns: patterns::POD_FAILURE_SIGNALS,
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::DataIntegrity,
        severity: IssueSeverity::Medium,
        summary: "Pod or container failure at runtime - possible product bug",
        include_pattern: false,
        guidance: RuleGuidance::Fix {
            target: None,
            hint: Some(
                "Runtime pod/container failure. Could be a suite error OR a product bug. \
                 Investigate whether the CRD, webhook, or controller is rejecting valid config.",
            ),
        },
        skip_if_matched: &[],
    },
    // Auth flow triggered
    TextRule {
        code: IssueCode::AuthFlowTriggered,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact(SourceTool::Bash),
        extra_guard: None,
        patterns: patterns::AUTH_SIGNALS,
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::UnexpectedBehavior,
        severity: IssueSeverity::Critical,
        summary: "OAuth/auth flow triggered - command tried to reach a real cluster",
        include_pattern: false,
        guidance: RuleGuidance::Fix {
            target: None,
            hint: Some(
                "Command attempted cluster auth. Block the binary in guard-bash or use local-only validation",
            ),
        },
        skip_if_matched: &[],
    },
    // Direct kubectl-validate usage
    TextRule {
        code: IssueCode::DirectKubectlValidateUsage,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact(SourceTool::Bash),
        extra_guard: None,
        patterns: &["kubectl-validate"],
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::SkillBehavior,
        severity: IssueSeverity::Critical,
        summary: "kubectl-validate used directly instead of harness authoring-validate",
        include_pattern: false,
        guidance: RuleGuidance::Fix {
            target: Some("skills/new/SKILL.md"),
            hint: Some(
                "Use harness authoring-validate, not kubectl-validate. kubectl-validate can reach real clusters.",
            ),
        },
        skip_if_matched: &[],
    },
    // Shell alias interference (cp -> rsync)
    TextRule {
        code: IssueCode::ShellAliasInterference,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact(SourceTool::Bash),
        extra_guard: None,
        patterns: &["rsync"],
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::UnexpectedBehavior,
        severity: IssueSeverity::Medium,
        summary: "Shell alias interference - rsync in cp output",
        include_pattern: false,
        guidance: RuleGuidance::Advisory {
            target: None,
            hint: "Shell alias resolved cp to rsync - use /bin/cp",
        },
        skip_if_matched: &[],
    },
    // Payload corruption (<json> tags around JSON)
    TextRule {
        code: IssueCode::PayloadWrappedInJsonTags,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact(SourceTool::Bash),
        extra_guard: None,
        patterns: &["<json>", "</json>"],
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::DataIntegrity,
        severity: IssueSeverity::Medium,
        summary: "Payload wrapped in <json> tags - data corruption from subagent",
        include_pattern: false,
        guidance: RuleGuidance::Fix {
            target: None,
            hint: Some(
                "Subagent output contains XML-style tags around JSON - strip before parsing",
            ),
        },
        skip_if_matched: &[],
    },
    // Python tracebacks
    TextRule {
        code: IssueCode::PythonTracebackOutput,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact(SourceTool::Bash),
        extra_guard: None,
        patterns: &["traceback (most recent call last)"],
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::BuildError,
        severity: IssueSeverity::Medium,
        summary: "Python traceback in command output",
        include_pattern: false,
        guidance: RuleGuidance::Fix {
            target: None,
            hint: Some("Python script failed - check input data or script logic"),
        },
        skip_if_matched: &[],
    },
    // Suite deviation signals (assistant text only, not tool output)
    TextRule {
        code: IssueCode::SuiteDeviationDetected,
        role_filter: RoleFilter::Exact(MessageRole::Assistant),
        source_tool_filter: ToolFilter::Absent,
        extra_guard: None,
        patterns: patterns::DEVIATION_SIGNALS,
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::SkillBehavior,
        severity: IssueSeverity::Critical,
        summary: "Suite deviation - baselines/manifests not distributed to all required clusters",
        include_pattern: false,
        guidance: RuleGuidance::Fix {
            target: Some("skills/new/SKILL.md"),
            hint: Some(
                "suite:new must distribute baselines to all clusters in multi-zone profiles",
            ),
        },
        skip_if_matched: &[],
    },
    // Release kumactl version (system binary instead of worktree build)
    TextRule {
        code: IssueCode::ReleaseKumactlBinaryUsed,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact(SourceTool::Bash),
        extra_guard: None,
        patterns: patterns::RELEASE_VERSION_SIGNALS,
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::SkillBehavior,
        severity: IssueSeverity::Critical,
        summary: "Release kumactl binary used instead of worktree build",
        include_pattern: false,
        guidance: RuleGuidance::Fix {
            target: Some("skills/run/SKILL.md"),
            hint: Some(
                "kumactl version shows a release build. The run should use \
                 kumactl built from the worktree under test, not the system binary.",
            ),
        },
        skip_if_matched: &[],
    },
    // Python usage in Bash commands
    TextRule {
        code: IssueCode::PythonUsedInBashOutput,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact(SourceTool::Bash),
        extra_guard: None,
        patterns: patterns::PYTHON_USAGE_SIGNALS,
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::UnexpectedBehavior,
        severity: IssueSeverity::Medium,
        summary: "Python used in Bash command - agents should never need python",
        include_pattern: false,
        guidance: RuleGuidance::Fix {
            target: None,
            hint: Some("Use harness commands or shell builtins instead of python one-liners"),
        },
        skip_if_matched: &[],
    },
    // Corporate / remote cluster context
    TextRule {
        code: IssueCode::CorporateClusterContextDetected,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact(SourceTool::Bash),
        extra_guard: None,
        patterns: patterns::CORPORATE_CLUSTER_SIGNALS,
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::UnexpectedBehavior,
        severity: IssueSeverity::Critical,
        summary: "Corporate/remote cluster context detected - should use local k3d",
        include_pattern: false,
        guidance: RuleGuidance::Fix {
            target: Some("skills/run/SKILL.md"),
            hint: Some(
                "Commands are hitting a remote cluster. Set KUBECONFIG to \
                 the local k3d config before running kubectl/harness commands.",
            ),
        },
        skip_if_matched: &[],
    },
];

/// Apply the static rule table against a text block. Returns the issues found
/// and the set of matched categories (for downstream skip logic).
pub(super) fn apply_text_rules(
    line_num: usize,
    role: MessageRole,
    text: &str,
    lower: &str,
    source_tool: Option<SourceTool>,
    state: &mut ScanState,
) -> (Vec<Issue>, HashSet<IssueCategory>) {
    let mut issues = Vec::new();
    let mut matched_categories = HashSet::new();
    let mut emitter = IssueEmitter::new(line_num, role, state);

    for rule in TEXT_RULES {
        if rule
            .skip_if_matched
            .iter()
            .any(|cat| matched_categories.contains(cat))
        {
            continue;
        }

        match rule.role_filter {
            RoleFilter::Exact(r) => {
                if role != r {
                    continue;
                }
            }
            RoleFilter::Any => {}
        }

        match rule.source_tool_filter {
            ToolFilter::Exact(t) => {
                if source_tool != Some(t) {
                    continue;
                }
            }
            ToolFilter::Absent => {
                if source_tool.is_some() {
                    continue;
                }
            }
            ToolFilter::Any => {}
        }

        if let Some(guard) = rule.extra_guard
            && !lower.contains(guard)
        {
            continue;
        }

        let matched_pattern = match rule.match_mode {
            MatchMode::FirstMatch => rule.patterns.iter().find(|p| lower.contains(*p)).copied(),
            MatchMode::Any => {
                if rule.patterns.iter().any(|p| lower.contains(p)) {
                    rule.patterns.iter().find(|p| lower.contains(*p)).copied()
                } else {
                    None
                }
            }
        };

        if let Some(pattern) = matched_pattern {
            let summary = if rule.include_pattern {
                format!("{}{pattern}", rule.summary)
            } else {
                rule.summary.to_string()
            };
            let fingerprint = match rule.fingerprint_mode {
                FingerprintMode::Static => rule.summary.to_string(),
                FingerprintMode::MatchedPattern => pattern.to_string(),
            };
            let blueprint = IssueBlueprint::new(rule.code, rule.category, rule.severity, summary)
                .with_fingerprint(fingerprint)
                .with_guidance(rule.guidance.into_guidance());
            emitter.emit(&mut issues, blueprint, text);
            matched_categories.insert(rule.category);
        }
    }

    (issues, matched_categories)
}
