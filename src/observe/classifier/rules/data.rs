use crate::observe::patterns;
use crate::observe::types::{IssueCategory, IssueCode, MessageRole, SourceTool};

use super::{
    FingerprintMode, Guard, MatchMode, RoleFilter, RuleGuidance, SummaryTemplate, TextRule,
    ToolFilter,
};

pub(crate) static TEXT_RULES: &[TextRule] = &[
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
    TextRule {
        code: IssueCode::DirectKubectlValidateUsage,
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact(SourceTool::Bash),
        guard: Guard::None,
        patterns: &["kubectl-validate"],
        match_mode: MatchMode::FirstMatch,
        fingerprint_mode: FingerprintMode::Static,
        summary: SummaryTemplate::Static(
            "kubectl-validate used directly instead of harness create-validate",
        ),
        guidance: RuleGuidance::Fix {
            target: Some("skills/create/SKILL.md"),
            hint: Some(
                "Use harness create-validate, not kubectl-validate. kubectl-validate can reach real clusters.",
            ),
        },
        skip_if_matched: &[],
    },
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
            target: Some("skills/create/SKILL.md"),
            hint: Some(
                "suite:create must distribute baselines to all clusters in multi-zone profiles",
            ),
        },
        skip_if_matched: &[],
    },
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
