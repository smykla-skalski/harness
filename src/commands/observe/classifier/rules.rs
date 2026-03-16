use std::collections::HashSet;

use super::emitter::{Guidance, IssueBlueprint, IssueEmitter};
use crate::commands::observe::patterns;
use crate::commands::observe::types::{
    Confidence, FixSafety, Issue, IssueCategory, IssueCode, IssueSeverity, MessageRole, ScanState,
    SourceTool,
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

/// Additional text guard applied before pattern matching.
#[derive(Clone, Copy)]
pub(super) enum Guard {
    None,
    Contains(&'static str),
}

impl Guard {
    fn matches(self, lower: &str) -> bool {
        match self {
            Self::None => true,
            Self::Contains(needle) => lower.contains(needle),
        }
    }
}

/// Static source of patterns for a declarative rule.
#[derive(Clone, Copy)]
pub(super) enum PatternSource {
    Literal(&'static [&'static str]),
    CliErrorPatterns,
    ToolErrorPatterns,
    BuildErrorPatterns,
    WorkflowErrorPatterns,
    PodFailureSignals,
    AuthSignals,
    DeviationSignals,
    ReleaseVersionSignals,
    PythonUsageSignals,
    CorporateClusterSignals,
}

impl PatternSource {
    fn as_slice(self) -> &'static [&'static str] {
        match self {
            Self::Literal(patterns) => patterns,
            Self::CliErrorPatterns => patterns::CLI_ERROR_PATTERNS,
            Self::ToolErrorPatterns => patterns::TOOL_ERROR_PATTERNS,
            Self::BuildErrorPatterns => patterns::BUILD_ERROR_PATTERNS,
            Self::WorkflowErrorPatterns => patterns::WORKFLOW_ERROR_PATTERNS,
            Self::PodFailureSignals => patterns::POD_FAILURE_SIGNALS,
            Self::AuthSignals => patterns::AUTH_SIGNALS,
            Self::DeviationSignals => patterns::DEVIATION_SIGNALS,
            Self::ReleaseVersionSignals => patterns::RELEASE_VERSION_SIGNALS,
            Self::PythonUsageSignals => patterns::PYTHON_USAGE_SIGNALS,
            Self::CorporateClusterSignals => patterns::CORPORATE_CLUSTER_SIGNALS,
        }
    }
}

/// How the rule summary is rendered for a hit.
#[derive(Clone, Copy)]
pub(super) enum SummaryTemplate {
    Static(&'static str),
    PrefixWithPattern(&'static str),
}

impl SummaryTemplate {
    fn render(self, matched_pattern: &str) -> String {
        match self {
            Self::Static(summary) => summary.to_string(),
            Self::PrefixWithPattern(prefix) => format!("{prefix}{matched_pattern}"),
        }
    }
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
    pub guard: Guard,
    pub patterns: PatternSource,
    pub match_mode: MatchMode,
    pub fingerprint_mode: FingerprintMode,
    pub category: IssueCategory,
    pub severity: IssueSeverity,
    pub confidence: Confidence,
    pub fix_safety: FixSafety,
    pub summary: SummaryTemplate,
    pub guidance: RuleGuidance,
    pub skip_if_matched: &'static [IssueCategory],
}

pub(super) static TEXT_RULES: &[TextRule] = &[
    // Hook denials
    TextRule {
        code: IssueCode::HookDeniedToolCall,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Any,
        guard: Guard::None,
        patterns: PatternSource::Literal(&["denied this tool", "blocked by hook"]),
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::HookFailure,
        severity: IssueSeverity::Medium,
        confidence: Confidence::High,
        fix_safety: FixSafety::TriageRequired,
        summary: SummaryTemplate::Static("Hook denied a tool call"),
        guidance: RuleGuidance::None,
        skip_if_matched: &[],
    },
    // CLI errors (marks CliError so build_errors can skip)
    TextRule {
        code: IssueCode::HarnessCliErrorOutput,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact(SourceTool::Bash),
        guard: Guard::Contains("harness"),
        patterns: PatternSource::CliErrorPatterns,
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::MatchedPattern,
        category: IssueCategory::CliError,
        severity: IssueSeverity::Medium,
        confidence: Confidence::High,
        fix_safety: FixSafety::AutoFixSafe,
        summary: SummaryTemplate::PrefixWithPattern("Harness CLI error: "),
        guidance: RuleGuidance::Fix {
            target: Some("src/cli.rs"),
            hint: None,
        },
        skip_if_matched: &[],
    },
    // Tool errors
    TextRule {
        code: IssueCode::ToolUsageErrorOutput,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Any,
        guard: Guard::None,
        patterns: PatternSource::ToolErrorPatterns,
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::MatchedPattern,
        category: IssueCategory::ToolError,
        severity: IssueSeverity::Low,
        confidence: Confidence::High,
        fix_safety: FixSafety::AdvisoryOnly,
        summary: SummaryTemplate::PrefixWithPattern("Tool usage error: "),
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
        guard: Guard::None,
        patterns: PatternSource::BuildErrorPatterns,
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::BuildError,
        severity: IssueSeverity::Critical,
        confidence: Confidence::High,
        fix_safety: FixSafety::AutoFixSafe,
        summary: SummaryTemplate::Static("Build or lint failure"),
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
        guard: Guard::None,
        patterns: PatternSource::WorkflowErrorPatterns,
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::MatchedPattern,
        category: IssueCategory::WorkflowError,
        severity: IssueSeverity::Medium,
        confidence: Confidence::High,
        fix_safety: FixSafety::AutoFixGuarded,
        summary: SummaryTemplate::PrefixWithPattern("Workflow state error: "),
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
        guard: Guard::None,
        patterns: PatternSource::PodFailureSignals,
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::DataIntegrity,
        severity: IssueSeverity::Medium,
        confidence: Confidence::Medium,
        fix_safety: FixSafety::TriageRequired,
        summary: SummaryTemplate::Static(
            "Pod or container failure at runtime - possible product bug",
        ),
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
        guard: Guard::None,
        patterns: PatternSource::AuthSignals,
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::UnexpectedBehavior,
        severity: IssueSeverity::Critical,
        confidence: Confidence::Medium,
        fix_safety: FixSafety::AutoFixSafe,
        summary: SummaryTemplate::Static(
            "OAuth/auth flow triggered - command tried to reach a real cluster",
        ),
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
        guard: Guard::None,
        patterns: PatternSource::Literal(&["kubectl-validate"]),
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::SkillBehavior,
        severity: IssueSeverity::Critical,
        confidence: Confidence::High,
        fix_safety: FixSafety::AutoFixSafe,
        summary: SummaryTemplate::Static(
            "kubectl-validate used directly instead of harness authoring-validate",
        ),
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
        guard: Guard::None,
        patterns: PatternSource::Literal(&["rsync"]),
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::UnexpectedBehavior,
        severity: IssueSeverity::Medium,
        confidence: Confidence::High,
        fix_safety: FixSafety::AdvisoryOnly,
        summary: SummaryTemplate::Static("Shell alias interference - rsync in cp output"),
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
        guard: Guard::None,
        patterns: PatternSource::Literal(&["<json>", "</json>"]),
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::DataIntegrity,
        severity: IssueSeverity::Medium,
        confidence: Confidence::High,
        fix_safety: FixSafety::AutoFixGuarded,
        summary: SummaryTemplate::Static(
            "Payload wrapped in <json> tags - data corruption from subagent",
        ),
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
        guard: Guard::None,
        patterns: PatternSource::Literal(&["traceback (most recent call last)"]),
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::BuildError,
        severity: IssueSeverity::Medium,
        confidence: Confidence::High,
        fix_safety: FixSafety::AutoFixGuarded,
        summary: SummaryTemplate::Static("Python traceback in command output"),
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
        guard: Guard::None,
        patterns: PatternSource::DeviationSignals,
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::SkillBehavior,
        severity: IssueSeverity::Critical,
        confidence: Confidence::Medium,
        fix_safety: FixSafety::TriageRequired,
        summary: SummaryTemplate::Static(
            "Suite deviation - baselines/manifests not distributed to all required clusters",
        ),
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
        guard: Guard::None,
        patterns: PatternSource::ReleaseVersionSignals,
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::SkillBehavior,
        severity: IssueSeverity::Critical,
        confidence: Confidence::High,
        fix_safety: FixSafety::AutoFixSafe,
        summary: SummaryTemplate::Static("Release kumactl binary used instead of worktree build"),
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
        guard: Guard::None,
        patterns: PatternSource::PythonUsageSignals,
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::UnexpectedBehavior,
        severity: IssueSeverity::Medium,
        confidence: Confidence::High,
        fix_safety: FixSafety::AutoFixSafe,
        summary: SummaryTemplate::Static(
            "Python used in Bash command - agents should never need python",
        ),
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
        guard: Guard::None,
        patterns: PatternSource::CorporateClusterSignals,
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
        category: IssueCategory::UnexpectedBehavior,
        severity: IssueSeverity::Critical,
        confidence: Confidence::High,
        fix_safety: FixSafety::AutoFixSafe,
        summary: SummaryTemplate::Static(
            "Corporate/remote cluster context detected - should use local k3d",
        ),
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

        if !rule.guard.matches(lower) {
            continue;
        }

        let patterns = rule.patterns.as_slice();
        let matched_pattern = match rule.match_mode {
            MatchMode::FirstMatch => patterns.iter().find(|p| lower.contains(*p)).copied(),
            MatchMode::Any => {
                if patterns.iter().any(|p| lower.contains(p)) {
                    patterns.iter().find(|p| lower.contains(*p)).copied()
                } else {
                    None
                }
            }
        };

        if let Some(pattern) = matched_pattern {
            let summary = rule.summary.render(pattern);
            let fingerprint = match rule.fingerprint_mode {
                FingerprintMode::Static => match rule.summary {
                    SummaryTemplate::Static(summary) => summary.to_string(),
                    SummaryTemplate::PrefixWithPattern(prefix) => prefix.to_string(),
                },
                FingerprintMode::MatchedPattern => pattern.to_string(),
            };
            let blueprint = IssueBlueprint::new(rule.code, rule.category, rule.severity, summary)
                .with_fingerprint(fingerprint)
                .with_guidance(rule.guidance.into_guidance())
                .with_confidence(rule.confidence)
                .with_fix_safety(rule.fix_safety)
                .with_source_tool(source_tool);
            emitter.emit(&mut issues, blueprint, text);
            matched_categories.insert(rule.category);
        }
    }

    (issues, matched_categories)
}
