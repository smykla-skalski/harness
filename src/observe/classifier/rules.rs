use std::collections::HashSet;

use super::emitter::{Guidance, IssueBlueprint, IssueEmitter};
use super::registry::issue_code_meta;
use crate::observe::patterns;
use crate::observe::types::{Issue, IssueCategory, IssueCode, MessageRole, ScanState, SourceTool};

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
    pub patterns: &'static [&'static str],
    pub match_mode: MatchMode,
    pub fingerprint_mode: FingerprintMode,
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
        patterns: &["denied this tool", "blocked by hook"],
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
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
        patterns: patterns::CLI_ERROR_PATTERNS,
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::MatchedPattern,
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
        patterns: patterns::TOOL_ERROR_PATTERNS,
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::MatchedPattern,
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
        patterns: patterns::BUILD_ERROR_PATTERNS,
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
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
        patterns: patterns::WORKFLOW_ERROR_PATTERNS,
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::MatchedPattern,
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
        patterns: patterns::POD_FAILURE_SIGNALS,
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
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
        patterns: patterns::AUTH_SIGNALS,
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
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
        patterns: &["kubectl-validate"],
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
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
        patterns: &["rsync"],
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
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
        patterns: &["<json>", "</json>"],
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
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
        patterns: &["traceback (most recent call last)"],
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
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
        patterns: patterns::DEVIATION_SIGNALS,
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
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
        patterns: patterns::RELEASE_VERSION_SIGNALS,
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
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
        patterns: patterns::PYTHON_USAGE_SIGNALS,
        match_mode: MatchMode::Any,
        fingerprint_mode: FingerprintMode::Static,
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
        patterns: patterns::CORPORATE_CLUSTER_SIGNALS,
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
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

/// Check whether a rule's filters (role, source tool, guard) all pass.
fn rule_matches_filters(
    text_rule: &TextRule,
    role: MessageRole,
    source_tool: Option<SourceTool>,
    lower: &str,
) -> bool {
    match text_rule.role_filter {
        RoleFilter::Exact(r) if role != r => return false,
        _ => {}
    }
    match text_rule.source_tool_filter {
        ToolFilter::Exact(t) if source_tool != Some(t) => return false,
        ToolFilter::Absent if source_tool.is_some() => return false,
        _ => {}
    }
    text_rule.guard.matches(lower)
}

/// Find the first matching pattern for a rule against lowercased text.
fn find_matched_pattern<'a>(rule: &'a TextRule, lower: &str) -> Option<&'a str> {
    match rule.match_mode {
        MatchMode::FirstMatch | MatchMode::Any => {
            rule.patterns.iter().find(|p| lower.contains(*p)).copied()
        }
    }
}

/// Derive the dedup fingerprint for a rule hit.
fn build_fingerprint(rule: &TextRule, pattern: &str) -> String {
    match rule.fingerprint_mode {
        FingerprintMode::Static => match rule.summary {
            SummaryTemplate::Static(summary) => summary.to_string(),
            SummaryTemplate::PrefixWithPattern(prefix) => prefix.to_string(),
        },
        FingerprintMode::MatchedPattern => pattern.to_string(),
    }
}

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
        if !rule_matches_filters(rule, role, source_tool, lower) {
            continue;
        }
        if let Some(pattern) = find_matched_pattern(rule, lower) {
            let fingerprint = build_fingerprint(rule, pattern);
            let meta =
                issue_code_meta(rule.code).expect("issue code registry should cover every code");
            let blueprint = IssueBlueprint::from_code(rule.code, rule.summary.render(pattern))
                .with_fingerprint(fingerprint)
                .with_guidance(rule.guidance.into_guidance())
                .with_source_tool(source_tool);
            emitter.emit(&mut issues, blueprint, text);
            matched_categories.insert(meta.default_category);
        }
    }

    (issues, matched_categories)
}
