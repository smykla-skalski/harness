use std::collections::HashSet;
use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

use super::patterns;
use super::tool_result_text;
use super::truncate_details;
use super::types::{Issue, IssueCategory, IssueSeverity, ScanState, ToolUseRecord};

/// Minimum text length to bother classifying.
const MIN_TEXT_LENGTH: usize = 5;

static EXIT_CODE_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"exit code (\d+)|exit: (\d+)").expect("valid regex"));
static AGENT_NAME_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"Agent "([^"]+)""#).expect("valid regex"));
static OLD_SKILL_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"--skill\s+(suite-author|suite-runner)\b").expect("valid regex"));
static RM_RECURSIVE_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\brm\s+(-\w+\s+)*.*-r").expect("valid regex"));
static SKILL_NAME_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^name:\s*(\S+)").expect("valid regex"));

// ─── Issue builder macro ───────────────────────────────────────────

/// Build an Issue with sensible defaults (fixable=false, no `fix_target`/`fix_hint`).
/// Optional trailing named fields override the defaults.
macro_rules! issue {
    ($line:expr, $role:expr, $text:expr, $cat:ident, $sev:ident, $summary:expr) => {
        Issue {
            line: $line,
            category: IssueCategory::$cat,
            severity: IssueSeverity::$sev,
            summary: String::from($summary),
            details: truncate_details($text),
            source_role: String::from($role),
            fixable: false,
            fix_target: None,
            fix_hint: None,
        }
    };
    ($line:expr, $role:expr, $text:expr, $cat:ident, $sev:ident, $summary:expr,
     $($field:ident : $val:expr),+ $(,)?) => {{
        #[allow(unused_mut)]
        let mut i = issue!($line, $role, $text, $cat, $sev, $summary);
        $(issue!(@set i, $field, $val);)+
        i
    }};
    (@set $i:ident, fixable, $val:expr) => { $i.fixable = $val; };
    (@set $i:ident, fix_target, $val:expr) => { $i.fix_target = Some(String::from($val)); };
    (@set $i:ident, fix_hint, $val:expr) => { $i.fix_hint = Some(String::from($val)); };
}

// ─── Heuristic guards ──────────────────────────────────────────────

/// Heuristic: text from the Read tool has line-numbered format.
fn is_file_content(text: &str) -> bool {
    let numbered = text
        .lines()
        .take(5)
        .filter(|line| {
            let trimmed = line.trim_start();
            trimmed.chars().next().is_some_and(|c| c.is_ascii_digit())
                && trimmed.contains('\u{2192}')
        })
        .count();
    numbered >= 2
}

/// Detect harness `--help` output (success, not error).
fn is_help_output(text: &str) -> bool {
    // Only need to check the prefix - no need to lowercase the entire text.
    let end = text.floor_char_boundary(text.len().min(200));
    let lower = text[..end].to_lowercase();
    let trimmed = lower.trim();
    trimmed.starts_with("kuma test harness")
        || (trimmed.starts_with("usage: harness") && !trimmed.contains("error:"))
        || trimmed.starts_with("handle session start hook\n\nusage:")
}

/// Detect compaction context injection.
fn is_compaction_summary(text: &str) -> bool {
    let end = text.floor_char_boundary(text.len().min(200));
    text[..end]
        .to_lowercase()
        .contains("this session is being continued from a previous conversation")
}

/// Detect skill content injected by Claude Code when a skill is loaded.
fn is_skill_injection(text: &str) -> bool {
    text.trim().starts_with("Base directory for this skill:")
}

/// Figure out which tool produced a `tool_result` block.
fn resolve_source_tool(block: &Value, state: &ScanState) -> Option<String> {
    let tool_id = block["tool_use_id"].as_str()?;
    state
        .last_tool_uses
        .get(tool_id)
        .map(|record| record.name.clone())
}

/// Return true if this issue is a duplicate that should be skipped.
fn dedup_issue(issue: &Issue, state: &mut ScanState) -> bool {
    let boundary = issue
        .summary
        .floor_char_boundary(issue.summary.len().min(80));
    let summary_prefix = &issue.summary[..boundary];
    let key = (issue.category.to_string(), summary_prefix.to_string());
    if state.seen_issues.contains(&key) {
        return true;
    }
    state.seen_issues.insert(key);
    false
}

// ─── Rule engine ───────────────────────────────────────────────────

/// Filter on message role.
#[derive(Clone, Copy)]
enum RoleFilter {
    /// No filter - any role matches.
    Any,
    /// Must match this exact role string.
    Exact(&'static str),
}

/// Filter on source tool.
#[derive(Clone, Copy)]
enum ToolFilter {
    /// No filter - any source tool (including None).
    Any,
    /// Must match this exact source tool.
    Exact(&'static str),
    /// Source tool must be None (plain text, not tool output).
    Absent,
}

/// How to match patterns against lowercased text.
#[derive(Clone, Copy)]
enum MatchMode {
    /// Stop at the first matching pattern; include it in summary if requested.
    FirstMatch,
    /// Check if any pattern matches (no specific pattern in summary).
    Any,
}

/// A declarative text classification rule. Rules are evaluated in order;
/// each matched rule adds its category to the matched set so later rules
/// can skip via `skip_if_matched`.
struct TextRule {
    role_filter: RoleFilter,
    source_tool_filter: ToolFilter,
    extra_guard: Option<&'static str>,
    patterns: &'static [&'static str],
    match_mode: MatchMode,
    category: IssueCategory,
    severity: IssueSeverity,
    summary: &'static str,
    include_pattern: bool,
    fixable: bool,
    fix_target: Option<&'static str>,
    fix_hint: Option<&'static str>,
    skip_if_matched: &'static [IssueCategory],
}

static TEXT_RULES: &[TextRule] = &[
    // Hook denials
    TextRule {
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Any,
        extra_guard: None,
        patterns: &["denied this tool", "blocked by hook"],
        match_mode: MatchMode::FirstMatch,
        category: IssueCategory::HookFailure,
        severity: IssueSeverity::Medium,
        summary: "Hook denied a tool call",
        include_pattern: false,
        fixable: false,
        fix_target: None,
        fix_hint: None,
        skip_if_matched: &[],
    },
    // CLI errors (marks CliError so build_errors can skip)
    TextRule {
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact("Bash"),
        extra_guard: Some("harness"),
        patterns: patterns::CLI_ERROR_PATTERNS,
        match_mode: MatchMode::FirstMatch,
        category: IssueCategory::CliError,
        severity: IssueSeverity::Medium,
        summary: "Harness CLI error: ",
        include_pattern: true,
        fixable: true,
        fix_target: Some("cli.rs"),
        fix_hint: None,
        skip_if_matched: &[],
    },
    // Tool errors
    TextRule {
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Any,
        extra_guard: None,
        patterns: patterns::TOOL_ERROR_PATTERNS,
        match_mode: MatchMode::FirstMatch,
        category: IssueCategory::ToolError,
        severity: IssueSeverity::Low,
        summary: "Tool usage error: ",
        include_pattern: true,
        fixable: false,
        fix_target: None,
        fix_hint: Some("Model behavior - read before edit"),
        skip_if_matched: &[],
    },
    // Build errors (skip when CLI error already matched)
    TextRule {
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact("Bash"),
        extra_guard: None,
        patterns: patterns::BUILD_ERROR_PATTERNS,
        match_mode: MatchMode::FirstMatch,
        category: IssueCategory::BuildError,
        severity: IssueSeverity::Critical,
        summary: "Build or lint failure",
        include_pattern: false,
        fixable: true,
        fix_target: None,
        fix_hint: Some("Fix the Rust code causing the failure"),
        skip_if_matched: &[IssueCategory::CliError],
    },
    // Workflow errors
    TextRule {
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact("Bash"),
        extra_guard: None,
        patterns: patterns::WORKFLOW_ERROR_PATTERNS,
        match_mode: MatchMode::FirstMatch,
        category: IssueCategory::WorkflowError,
        severity: IssueSeverity::Medium,
        summary: "Workflow state error: ",
        include_pattern: true,
        fixable: true,
        fix_target: None,
        fix_hint: Some("Check workflow state machine logic"),
        skip_if_matched: &[],
    },
    // Pod / container failures
    TextRule {
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact("Bash"),
        extra_guard: None,
        patterns: patterns::POD_FAILURE_SIGNALS,
        match_mode: MatchMode::Any,
        category: IssueCategory::SkillBehavior,
        severity: IssueSeverity::Critical,
        summary: "Authored manifest caused runtime failure",
        include_pattern: false,
        fixable: true,
        fix_target: Some("skills/new/SKILL.md"),
        fix_hint: Some("suite:new produced a manifest with outdated or invalid config"),
        skip_if_matched: &[],
    },
    // Auth flow triggered
    TextRule {
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact("Bash"),
        extra_guard: None,
        patterns: patterns::AUTH_SIGNALS,
        match_mode: MatchMode::Any,
        category: IssueCategory::UnexpectedBehavior,
        severity: IssueSeverity::Critical,
        summary: "OAuth/auth flow triggered - command tried to reach a real cluster",
        include_pattern: false,
        fixable: true,
        fix_target: None,
        fix_hint: Some(
            "Command attempted cluster auth. Block the binary in guard-bash or use local-only validation",
        ),
        skip_if_matched: &[],
    },
    // Direct kubectl-validate usage
    TextRule {
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact("Bash"),
        extra_guard: None,
        patterns: &["kubectl-validate"],
        match_mode: MatchMode::FirstMatch,
        category: IssueCategory::SkillBehavior,
        severity: IssueSeverity::Critical,
        summary: "kubectl-validate used directly instead of harness authoring-validate",
        include_pattern: false,
        fixable: true,
        fix_target: Some("skills/new/SKILL.md"),
        fix_hint: Some(
            "Use harness authoring-validate, not kubectl-validate. kubectl-validate can reach real clusters.",
        ),
        skip_if_matched: &[],
    },
    // Shell alias interference (cp -> rsync)
    TextRule {
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact("Bash"),
        extra_guard: None,
        patterns: &["rsync"],
        match_mode: MatchMode::FirstMatch,
        category: IssueCategory::UnexpectedBehavior,
        severity: IssueSeverity::Medium,
        summary: "Shell alias interference - rsync in cp output",
        include_pattern: false,
        fixable: false,
        fix_target: None,
        fix_hint: Some("Shell alias resolved cp to rsync - use /bin/cp"),
        skip_if_matched: &[],
    },
    // Payload corruption (<json> tags around JSON)
    TextRule {
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact("Bash"),
        extra_guard: None,
        patterns: &["<json>", "</json>"],
        match_mode: MatchMode::Any,
        category: IssueCategory::DataIntegrity,
        severity: IssueSeverity::Medium,
        summary: "Payload wrapped in <json> tags - data corruption from subagent",
        include_pattern: false,
        fixable: true,
        fix_target: None,
        fix_hint: Some(
            "Subagent output contains XML-style tags around JSON - strip before parsing",
        ),
        skip_if_matched: &[],
    },
    // Python tracebacks
    TextRule {
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact("Bash"),
        extra_guard: None,
        patterns: &["traceback (most recent call last)"],
        match_mode: MatchMode::FirstMatch,
        category: IssueCategory::BuildError,
        severity: IssueSeverity::Medium,
        summary: "Python traceback in command output",
        include_pattern: false,
        fixable: true,
        fix_target: None,
        fix_hint: Some("Python script failed - check input data or script logic"),
        skip_if_matched: &[],
    },
    // Suite deviation signals (assistant text only, not tool output)
    TextRule {
        role_filter: RoleFilter::Exact("assistant"),
        source_tool_filter: ToolFilter::Absent,
        extra_guard: None,
        patterns: patterns::DEVIATION_SIGNALS,
        match_mode: MatchMode::Any,
        category: IssueCategory::SkillBehavior,
        severity: IssueSeverity::Critical,
        summary: "Suite deviation - baselines/manifests not distributed to all required clusters",
        include_pattern: false,
        fixable: true,
        fix_target: Some("skills/new/SKILL.md"),
        fix_hint: Some(
            "suite:new must distribute baselines to all clusters in multi-zone profiles",
        ),
        skip_if_matched: &[],
    },
    // Release kumactl version (system binary instead of worktree build)
    TextRule {
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact("Bash"),
        extra_guard: None,
        patterns: patterns::RELEASE_VERSION_SIGNALS,
        match_mode: MatchMode::Any,
        category: IssueCategory::SkillBehavior,
        severity: IssueSeverity::Critical,
        summary: "Release kumactl binary used instead of worktree build",
        include_pattern: false,
        fixable: true,
        fix_target: Some("skills/run/SKILL.md"),
        fix_hint: Some(
            "kumactl version shows a release build. The run should use \
             kumactl built from the worktree under test, not the system binary.",
        ),
        skip_if_matched: &[],
    },
    // Python usage in Bash commands
    TextRule {
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact("Bash"),
        extra_guard: None,
        patterns: patterns::PYTHON_USAGE_SIGNALS,
        match_mode: MatchMode::Any,
        category: IssueCategory::UnexpectedBehavior,
        severity: IssueSeverity::Medium,
        summary: "Python used in Bash command - agents should never need python",
        include_pattern: false,
        fixable: true,
        fix_target: None,
        fix_hint: Some("Use harness commands or shell builtins instead of python one-liners"),
        skip_if_matched: &[],
    },
    // Corporate / remote cluster context
    TextRule {
        role_filter: RoleFilter::Any,
        source_tool_filter: ToolFilter::Exact("Bash"),
        extra_guard: None,
        patterns: patterns::CORPORATE_CLUSTER_SIGNALS,
        match_mode: MatchMode::FirstMatch,
        category: IssueCategory::UnexpectedBehavior,
        severity: IssueSeverity::Critical,
        summary: "Corporate/remote cluster context detected - should use local k3d",
        include_pattern: false,
        fixable: true,
        fix_target: Some("skills/run/SKILL.md"),
        fix_hint: Some(
            "Commands are hitting a remote cluster. Set KUBECONFIG to \
             the local k3d config before running kubectl/harness commands.",
        ),
        skip_if_matched: &[],
    },
];

/// Apply the static rule table against a text block. Returns the issues found
/// and the set of matched categories (for downstream skip logic).
fn apply_text_rules(
    line_num: usize,
    role: &str,
    text: &str,
    lower: &str,
    source_tool: Option<&str>,
) -> (Vec<Issue>, HashSet<IssueCategory>) {
    let mut issues = Vec::new();
    let mut matched_categories = HashSet::new();

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
                    Some("")
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
            issues.push(Issue {
                line: line_num,
                category: rule.category,
                severity: rule.severity,
                summary,
                details: truncate_details(text),
                source_role: role.to_string(),
                fixable: rule.fixable,
                fix_target: rule.fix_target.map(String::from),
                fix_hint: rule.fix_hint.map(String::from),
            });
            matched_categories.insert(rule.category);
        }
    }

    (issues, matched_categories)
}

// ─── Complex standalone checks ─────────────────────────────────────
// These need regex extraction, multi-branch logic, or dynamic summaries
// that don't fit the declarative rule table.

/// Check for KSA hook codes in Bash output.
fn check_ksa_codes(
    line_num: usize,
    role: &str,
    text: &str,
    lower: &str,
    source_tool: Option<&str>,
    issues: &mut Vec<Issue>,
) {
    if source_tool != Some("Bash") {
        return;
    }
    for code in patterns::KSA_CODES {
        if lower.contains(code) {
            let display_code = code.to_uppercase();
            issues.push(issue!(
                line_num,
                role,
                text,
                HookFailure,
                Medium,
                format!("Harness hook code {display_code} triggered"),
                fixable: true,
                fix_hint: format!("Check hook logic for {display_code}"),
            ));
            break;
        }
    }
}

/// Check for harness command failures with non-zero exit codes.
fn check_exit_code_issues(
    line_num: usize,
    role: &str,
    text: &str,
    lower: &str,
    source_tool: Option<&str>,
    issues: &mut Vec<Issue>,
    matched_categories: &HashSet<IssueCategory>,
) {
    if source_tool != Some("Bash") {
        return;
    }

    let is_harness_operation = patterns::HARNESS_OPERATION_KEYWORDS
        .iter()
        .any(|keyword| lower.contains(keyword));

    let Some(captures) = EXIT_CODE_REGEX.captures(lower) else {
        return;
    };

    let code_str = captures
        .get(1)
        .or_else(|| captures.get(2))
        .map_or("0", |m| m.as_str());
    let exit_code: u32 = code_str.parse().unwrap_or(0);

    if exit_code == 0
        || matched_categories.contains(&IssueCategory::BuildError)
        || matched_categories.contains(&IssueCategory::CliError)
    {
        return;
    }

    let is_harness_authoring = lower.contains("harness") && lower.contains("authoring");

    if is_harness_operation {
        issues.push(issue!(
            line_num,
            role,
            text,
            SkillBehavior,
            Medium,
            format!("Authored manifest failed at runtime (exit {exit_code})"),
            fixable: true,
            fix_target: "skills/new/SKILL.md",
            fix_hint: "suite:new produced manifests that fail preflight/apply/validate - check authoring validation",
        ));
    } else if is_harness_authoring {
        issues.push(issue!(
            line_num,
            role,
            text,
            WorkflowError,
            Medium,
            format!("Harness authoring command failed (exit {exit_code})"),
            fixable: true,
            fix_hint:
                "Harness authoring command returned non-zero - check payload or arguments",
        ));
    } else if exit_code != 1 {
        issues.push(issue!(
            line_num,
            role,
            text,
            SubagentIssue,
            Low,
            format!("Non-zero exit code {exit_code}"),
            fix_hint: format!("Command exited with code {exit_code}"),
        ));
    }
}

/// Check for subagent permission failures in user-role text.
fn check_permission_failures(
    line_num: usize,
    role: &str,
    text: &str,
    lower: &str,
    source_tool: Option<&str>,
    issues: &mut Vec<Issue>,
) {
    if role != "user" || source_tool.is_some() {
        return;
    }
    if !patterns::PERMISSION_SIGNALS
        .iter()
        .any(|signal| lower.contains(signal))
    {
        return;
    }
    let agent_name = AGENT_NAME_REGEX
        .captures(text)
        .and_then(|c| c.get(1))
        .map_or("unknown", |m| m.as_str());
    issues.push(issue!(
        line_num,
        role,
        text,
        SubagentIssue,
        Medium,
        format!("Subagent '{agent_name}' blocked by missing permissions"),
        fixable: true,
        fix_hint: "Subagent needs permissionMode dontAsk or mode auto for Bash/Write",
    ));
}

/// Check for subagent save failures in assistant text.
fn check_save_failures(
    line_num: usize,
    role: &str,
    text: &str,
    lower: &str,
    source_tool: Option<&str>,
    issues: &mut Vec<Issue>,
) {
    if role != "assistant" || source_tool.is_some() {
        return;
    }
    if !patterns::SAVE_FAILURE_SIGNALS
        .iter()
        .any(|signal| lower.contains(signal))
    {
        return;
    }
    let context: String = text.chars().take(40).collect();
    let context = context.replace('\n', " ");
    issues.push(issue!(
        line_num,
        role,
        text,
        SubagentIssue,
        Medium,
        format!("Subagent manual recovery: {context}"),
        fixable: true,
        fix_hint: "Subagent lacks write permissions or hit a harness CLI error during save",
    ));
}

/// Check for manual payload recovery patterns.
fn check_payload_recovery(
    line_num: usize,
    role: &str,
    text: &str,
    lower: &str,
    source_tool: Option<&str>,
    issues: &mut Vec<Issue>,
) {
    if role != "assistant" || source_tool.is_some() {
        return;
    }
    let has_grep = lower.contains("grep");
    let has_target =
        lower.contains("output") || lower.contains("transcript") || lower.contains("payload");
    let has_recovery = lower.contains("found the full payload")
        || lower.contains("extract and save")
        || lower.contains("grab its");
    if has_grep && has_target && has_recovery {
        issues.push(issue!(
            line_num,
            role,
            text,
            SubagentIssue,
            Medium,
            "Manual payload recovery from subagent output",
            fixable: true,
            fix_hint:
                "Subagent should save its own payload - manual grep recovery is a workflow failure",
        ));
    }
}

/// Check for misconfigured environment variables in Bash output.
/// Uses the `ENV_MISCONFIGURATION_SIGNALS` pattern array from patterns.rs.
fn check_env_misconfiguration(
    line_num: usize,
    role: &str,
    text: &str,
    lower: &str,
    source_tool: Option<&str>,
    issues: &mut Vec<Issue>,
) {
    if source_tool != Some("Bash") {
        return;
    }
    for signal in patterns::ENV_MISCONFIGURATION_SIGNALS {
        if !lower.contains(signal) {
            continue;
        }
        if signal.contains("claude_session_id") {
            issues.push(issue!(
                line_num,
                role,
                text,
                DataIntegrity,
                Critical,
                "CLAUDE_SESSION_ID is unset - harness cannot resolve session context",
                fixable: true,
                fix_target: "src/context.rs",
                fix_hint: "Session ID env var not set. Harness init and runner-state \
                           cannot find the context directory without it.",
            ));
        } else if signal.contains("kubeconfig") {
            issues.push(issue!(
                line_num,
                role,
                text,
                SkillBehavior,
                Critical,
                "KUBECONFIG is empty - cluster commands will hit default context",
                fixable: true,
                fix_target: "skills/run/SKILL.md",
                fix_hint: "harness cluster should set KUBECONFIG to the k3d cluster config. \
                           Without it, kubectl defaults to ~/.kube/config which may point \
                           to a corporate cluster.",
            ));
        }
    }
}

/// Check for user frustration signals in human text.
fn check_user_frustration(
    line_num: usize,
    role: &str,
    text: &str,
    lower: &str,
    source_tool: Option<&str>,
    issues: &mut Vec<Issue>,
) {
    if role != "user" || source_tool.is_some() || text.len() >= 2000 {
        return;
    }
    let exclamation_count = text.chars().filter(|&c| c == '!').count();
    let has_signal = patterns::USER_FRUSTRATION_SIGNALS
        .iter()
        .any(|signal| lower.contains(signal));

    if exclamation_count >= 4 || has_signal {
        issues.push(issue!(
            line_num,
            role,
            text,
            UserFrustration,
            Medium,
            "User frustration signal detected",
            fix_hint: "Review what happened before this - likely a UX issue",
        ));
    }
}

// ─── Public API ────────────────────────────────────────────────────

/// Classify text content for issues.
///
/// `source_tool` is the tool that produced this text (e.g. "Bash", "Read") -
/// `None` for assistant/human text blocks.
#[must_use]
pub fn check_text_for_issues(
    line_num: usize,
    role: &str,
    text: &str,
    source_tool: Option<&str>,
) -> Vec<Issue> {
    if source_tool == Some("Read") || is_file_content(text) {
        return Vec::new();
    }
    if is_help_output(text) || is_compaction_summary(text) || is_skill_injection(text) {
        return Vec::new();
    }

    let lower = text.to_lowercase();

    // Rule table handles the 15 simple pattern-matching checks.
    let (mut issues, matched_categories) =
        apply_text_rules(line_num, role, text, &lower, source_tool);

    // Complex standalone checks that need regex, multi-branch, or dynamic formatting.
    check_ksa_codes(line_num, role, text, &lower, source_tool, &mut issues);
    check_exit_code_issues(
        line_num,
        role,
        text,
        &lower,
        source_tool,
        &mut issues,
        &matched_categories,
    );
    check_permission_failures(line_num, role, text, &lower, source_tool, &mut issues);
    check_save_failures(line_num, role, text, &lower, source_tool, &mut issues);
    check_payload_recovery(line_num, role, text, &lower, source_tool, &mut issues);
    check_env_misconfiguration(line_num, role, text, &lower, source_tool, &mut issues);
    check_user_frustration(line_num, role, text, &lower, source_tool, &mut issues);

    issues
}

/// Check a `tool_use` block for issues.
pub fn check_tool_use_for_issues(
    line_num: usize,
    block: &Value,
    state: &mut ScanState,
) -> Vec<Issue> {
    let mut issues = Vec::new();
    let name = block["name"].as_str().unwrap_or("");
    let input = &block["input"];

    if name == "Bash" {
        check_bash_tool_use(line_num, input, &mut issues);
    }

    if name == "AskUserQuestion" {
        check_ask_user_question(line_num, input, &mut issues);
    }

    if name == "Write" || name == "Edit" {
        check_write_edit_tool_use(line_num, name, input, state, &mut issues);
        check_managed_file_writes(line_num, input, &mut issues);
    }

    // Record tool_use for correlating with tool_result.
    if let Some(tool_id) = block["id"].as_str()
        && !tool_id.is_empty()
    {
        state.last_tool_uses.insert(
            tool_id.to_string(),
            ToolUseRecord {
                name: name.to_string(),
                input: input.clone(),
            },
        );
    }

    issues
}

// ─── tool_use sub-checks ───────────────────────────────────────────

/// Check Bash `tool_use` for specific patterns.
fn check_bash_tool_use(line_num: usize, input: &Value, issues: &mut Vec<Issue>) {
    let command = input["command"].as_str().unwrap_or("");

    if OLD_SKILL_REGEX.is_match(command) {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::NamingError,
            severity: IssueSeverity::Medium,
            summary: "Old skill name used in harness command".into(),
            details: format!("Command: {command}"),
            source_role: "assistant".into(),
            fixable: true,
            fix_target: None,
            fix_hint: Some("SKILL.md or model still references old skill names".into()),
        });
    }

    if command.contains("harness") && command.contains("validator-decision") {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::CliError,
            severity: IssueSeverity::Medium,
            summary: "Invalid harness subcommand/argument used".into(),
            details: format!("Command: {command}"),
            source_role: "assistant".into(),
            fixable: true,
            fix_target: None,
            fix_hint: Some("SKILL.md references a non-existent harness kind".into()),
        });
    }

    let command_lower = command.to_lowercase();
    if patterns::PYTHON_USAGE_SIGNALS
        .iter()
        .any(|signal| command_lower.contains(signal))
    {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::UnexpectedBehavior,
            severity: IssueSeverity::Medium,
            summary: "Python used in Bash command - agents should never need python".into(),
            details: format!("Command: {command}"),
            source_role: "assistant".into(),
            fixable: true,
            fix_target: None,
            fix_hint: Some(
                "Use harness commands or shell builtins instead of python one-liners".into(),
            ),
        });
    }

    if RM_RECURSIVE_REGEX.is_match(command) && !command.contains("&&") {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::UnexpectedBehavior,
            severity: IssueSeverity::Medium,
            summary: "Destructive rm -r without chained verification".into(),
            details: format!("Command: {command}"),
            source_role: "assistant".into(),
            fixable: false,
            fix_target: None,
            fix_hint: Some("Should verify target exists and is correct before deleting".into()),
        });
    }
}

/// Check `AskUserQuestion` `tool_use` for issue patterns.
fn check_ask_user_question(line_num: usize, input: &Value, issues: &mut Vec<Issue>) {
    let Some(questions) = input["questions"].as_array() else {
        return;
    };

    for question_block in questions {
        let question_text = question_block["question"].as_str().unwrap_or("");
        let question_lower = question_text.to_lowercase();
        let options = question_block["options"].as_array();
        let header = question_block["header"].as_str().unwrap_or("");

        check_manifest_fix_prompt(line_num, question_text, &question_lower, issues);
        check_validator_install_prompt(line_num, question_text, &question_lower, issues);
        check_question_deviations(
            line_num,
            question_text,
            &question_lower,
            header,
            options,
            issues,
        );
        check_wrong_skill_crossref(line_num, question_text, &question_lower, options, issues);
    }
}

/// Check for manifest-fix prompt in a question.
fn check_manifest_fix_prompt(
    line_num: usize,
    question_text: &str,
    question_lower: &str,
    issues: &mut Vec<Issue>,
) {
    if question_text.contains("manifest-fix") && question_lower.contains("how should this failure")
    {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::SkillBehavior,
            severity: IssueSeverity::Critical,
            summary: "Manifest fix needed at runtime - authored suite has broken manifest".into(),
            details: format!("Question: {question_text}"),
            source_role: "assistant".into(),
            fixable: true,
            fix_target: Some("skills/new/SKILL.md".into()),
            fix_hint: Some(
                "suite:new produced a manifest that fails at runtime and requires manual correction"
                    .into(),
            ),
        });
    }
}

/// Check for `kubectl-validate` install prompt.
fn check_validator_install_prompt(
    line_num: usize,
    question_text: &str,
    question_lower: &str,
    issues: &mut Vec<Issue>,
) {
    if question_text.contains("kubectl-validate") && question_lower.contains("install") {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::SkillBehavior,
            severity: IssueSeverity::Medium,
            summary: "Validator install prompt when binary may already exist".into(),
            details: format!("Question: {question_text}"),
            source_role: "assistant".into(),
            fixable: true,
            fix_target: Some("skills/new/SKILL.md".into()),
            fix_hint: Some("Step 0 should check if binary exists first".into()),
        });
    }
}

/// Check for runtime deviation signals in a question's full text.
/// Short-circuits per part rather than joining into one big string.
fn check_question_deviations(
    line_num: usize,
    question_text: &str,
    question_lower: &str,
    header: &str,
    options: Option<&Vec<Value>>,
    issues: &mut Vec<Issue>,
) {
    let has_signal = |text: &str| -> bool {
        patterns::QUESTION_DEVIATION_SIGNALS
            .iter()
            .any(|signal| text.contains(signal))
    };

    let header_lower = header.to_lowercase();
    let found = has_signal(&header_lower)
        || has_signal(question_lower)
        || options.is_some_and(|opts| {
            opts.iter().any(|opt| {
                opt["label"]
                    .as_str()
                    .is_some_and(|s| has_signal(&s.to_lowercase()))
                    || opt["description"]
                        .as_str()
                        .is_some_and(|s| has_signal(&s.to_lowercase()))
                    || opt.as_str().is_some_and(|s| has_signal(&s.to_lowercase()))
            })
        });

    if found {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::SkillBehavior,
            severity: IssueSeverity::Critical,
            summary: "Runtime deviation - authored suite needs runtime correction".into(),
            details: format!("Header: {header}, Question: {question_text}"),
            source_role: "assistant".into(),
            fixable: true,
            fix_target: Some("skills/new/SKILL.md".into()),
            fix_hint: Some(
                "suite:new should produce suites that don't require runtime deviations".into(),
            ),
        });
    }
}

/// Check for wrong skill cross-references in question options.
fn check_wrong_skill_crossref(
    line_num: usize,
    question_text: &str,
    question_lower: &str,
    options: Option<&Vec<Value>>,
    issues: &mut Vec<Issue>,
) {
    let Some(opts) = options else {
        return;
    };
    for opt in opts {
        let label = opt["label"].as_str().or_else(|| opt.as_str()).unwrap_or("");
        if label.to_lowercase().contains("suite:new") && question_lower.contains("suite:run") {
            issues.push(Issue {
                line: line_num,
                category: IssueCategory::SkillBehavior,
                severity: IssueSeverity::Medium,
                summary: "suite:run offering suite:new as structured choice".into(),
                details: format!("Question: {question_text}, Option: {label}"),
                source_role: "assistant".into(),
                fixable: true,
                fix_target: Some("skills/run/SKILL.md".into()),
                fix_hint: Some(
                    "suite:run should not offer suite:new as a structured option".into(),
                ),
            });
        }
    }
}

/// Check Write/Edit `tool_use` for churn and naming issues.
fn check_write_edit_tool_use(
    line_num: usize,
    tool_name: &str,
    input: &Value,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    let path = input["file_path"].as_str().unwrap_or("");

    let count = state.edit_counts.entry(path.to_string()).or_insert(0);
    *count += 1;

    if *count == 10 || *count == 20 {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::UnexpectedBehavior,
            severity: IssueSeverity::Medium,
            summary: format!("File modified {} times - possible churn", *count),
            details: format!("Path: {path}"),
            source_role: "assistant".into(),
            fixable: false,
            fix_target: None,
            fix_hint: Some("Repeated modifications suggest trial-and-error".into()),
        });
    }

    if path.contains("SKILL.md") {
        let content = if tool_name == "Write" {
            input["content"].as_str().unwrap_or("")
        } else {
            input["new_string"].as_str().unwrap_or("")
        };
        if let Some(captures) = SKILL_NAME_REGEX.captures(content) {
            let skill_name = captures.get(1).map_or("", |m| m.as_str());
            if matches!(skill_name, "new" | "run" | "observe") && !skill_name.contains(':') {
                issues.push(Issue {
                    line: line_num,
                    category: IssueCategory::SkillBehavior,
                    severity: IssueSeverity::Critical,
                    summary: format!(
                        "SKILL.md name field uses short name '{skill_name}' instead of fully qualified"
                    ),
                    details: format!("Path: {path}, name: {skill_name}"),
                    source_role: "assistant".into(),
                    fixable: true,
                    fix_target: Some(path.to_string()),
                    fix_hint: Some(
                        "Name should be fully qualified like 'suite:new' or 'suite:run'".into(),
                    ),
                });
            }
        }
    }
}

/// Check for direct writes to harness-managed files via Write/Edit tools.
fn check_managed_file_writes(line_num: usize, input: &Value, issues: &mut Vec<Issue>) {
    let path = input["file_path"].as_str().unwrap_or("");
    let path_lower = path.to_lowercase();
    for managed in patterns::MANAGED_CONTEXT_FILES {
        if path_lower.contains(managed) {
            issues.push(Issue {
                line: line_num,
                category: IssueCategory::UnexpectedBehavior,
                severity: IssueSeverity::Critical,
                summary: format!("Direct write to harness-managed file: {managed}"),
                details: format!("Path: {path}"),
                source_role: "assistant".into(),
                fixable: true,
                fix_target: Some("skills/run/SKILL.md".into()),
                fix_hint: Some(
                    "Use harness commands to update managed files, not direct Write/Edit".into(),
                ),
            });
            break;
        }
    }
}

// ─── Line-level classifier ─────────────────────────────────────────

/// Classify a single JSONL line from a session log.
///
/// Parses the JSON, dispatches to text/`tool_use` checkers, and deduplicates.
pub fn classify_line(line_num: usize, raw: &str, state: &mut ScanState) -> Vec<Issue> {
    let obj: Value = match serde_json::from_str(raw.trim()) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };

    if state.session_start_timestamp.is_none()
        && let Some(ts) = obj["timestamp"].as_str()
    {
        state.session_start_timestamp = Some(ts.to_string());
    }

    let message = &obj["message"];
    if !message.is_object() {
        return Vec::new();
    }

    let role = message["role"].as_str().unwrap_or("");
    let content = &message["content"];
    let mut issues = Vec::new();

    if let Some(blocks) = content.as_array() {
        classify_content_blocks(line_num, role, blocks, state, &mut issues);
    } else if let Some(text) = content.as_str()
        && text.len() > MIN_TEXT_LENGTH
    {
        issues.extend(check_text_for_issues(line_num, role, text, None));
    }

    issues.retain(|issue| !dedup_issue(issue, state));
    issues
}

/// Process content blocks from a message.
fn classify_content_blocks(
    line_num: usize,
    role: &str,
    blocks: &[Value],
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    for block in blocks {
        let block_type = block["type"].as_str().unwrap_or("");
        match block_type {
            "text" => {
                let text = block["text"].as_str().unwrap_or("");
                if text.len() > MIN_TEXT_LENGTH {
                    issues.extend(check_text_for_issues(line_num, role, text, None));
                }
            }
            "tool_use" => {
                issues.extend(check_tool_use_for_issues(line_num, block, state));
            }
            "tool_result" => {
                let text = tool_result_text(block);
                if text.len() > MIN_TEXT_LENGTH {
                    let source = resolve_source_tool(block, state);
                    issues.extend(check_text_for_issues(
                        line_num,
                        role,
                        &text,
                        source.as_deref(),
                    ));
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_state() -> ScanState {
        ScanState::default()
    }

    #[test]
    fn detects_hook_denial() {
        let issues = check_text_for_issues(
            10,
            "user",
            "The system denied this tool call because it violates policy",
            None,
        );
        assert_eq!(issues.len(), 1);
        assert_eq!(issues[0].category, IssueCategory::HookFailure);
    }

    #[test]
    fn detects_ksa_code_in_bash() {
        let issues = check_text_for_issues(
            20,
            "user",
            "ERROR [KSA001] Write path is outside the suite:new surface",
            Some("Bash"),
        );
        assert!(
            issues
                .iter()
                .any(|i| i.category == IssueCategory::HookFailure)
        );
    }

    #[test]
    fn skips_ksa_code_not_bash() {
        let issues =
            check_text_for_issues(20, "user", "ERROR [KSA001] Write path is outside", None);
        assert!(!issues.iter().any(|i| i.summary.contains("KSA001")));
    }

    #[test]
    fn detects_cli_error() {
        let issues = check_text_for_issues(
            30,
            "user",
            "harness: error: unrecognized arguments --bad-flag",
            Some("Bash"),
        );
        assert!(issues.iter().any(|i| i.category == IssueCategory::CliError));
    }

    #[test]
    fn detects_tool_error() {
        let issues = check_text_for_issues(
            40,
            "user",
            "Error: file has not been read yet. Read the file first.",
            None,
        );
        assert!(
            issues
                .iter()
                .any(|i| i.category == IssueCategory::ToolError)
        );
    }

    #[test]
    fn detects_build_error() {
        let issues = check_text_for_issues(
            50,
            "user",
            "error[E0308]: mismatched types\n  expected u32, found &str",
            Some("Bash"),
        );
        assert!(
            issues
                .iter()
                .any(|i| i.category == IssueCategory::BuildError)
        );
    }

    #[test]
    fn detects_user_frustration() {
        let issues = check_text_for_issues(60, "user", "stop guessing and read it again!", None);
        assert!(
            issues
                .iter()
                .any(|i| i.category == IssueCategory::UserFrustration)
        );
    }

    #[test]
    fn skips_file_content() {
        let text = "     1\u{2192}fn main() {\n     2\u{2192}    println!(\"error[E0308]\");\n     3\u{2192}}";
        let issues = check_text_for_issues(70, "user", text, None);
        assert!(issues.is_empty());
    }

    #[test]
    fn skips_help_output() {
        let issues = check_text_for_issues(
            80,
            "user",
            "Kuma test harness\n\nUsage: harness [COMMAND]",
            Some("Bash"),
        );
        assert!(issues.is_empty());
    }

    #[test]
    fn skips_compaction_summary() {
        let issues = check_text_for_issues(
            90,
            "user",
            "This session is being continued from a previous conversation. Here is context.",
            None,
        );
        assert!(issues.is_empty());
    }

    #[test]
    fn detects_auth_flow() {
        let issues = check_text_for_issues(
            100,
            "user",
            "Opening browser for authentication to your cluster",
            Some("Bash"),
        );
        assert!(
            issues
                .iter()
                .any(|i| i.category == IssueCategory::UnexpectedBehavior)
        );
    }

    #[test]
    fn detects_old_skill_name_in_bash() {
        let mut state = make_state();
        let block = serde_json::json!({
            "type": "tool_use",
            "id": "t1",
            "name": "Bash",
            "input": { "command": "harness hook --skill suite-runner guard-bash" }
        });
        let issues = check_tool_use_for_issues(10, &block, &mut state);
        assert!(
            issues
                .iter()
                .any(|i| i.category == IssueCategory::NamingError)
        );
    }

    #[test]
    fn tracks_tool_use_for_correlation() {
        let mut state = make_state();
        let block = serde_json::json!({
            "type": "tool_use",
            "id": "tool_abc",
            "name": "Bash",
            "input": { "command": "ls" }
        });
        check_tool_use_for_issues(10, &block, &mut state);
        assert!(state.last_tool_uses.contains_key("tool_abc"));
        assert_eq!(state.last_tool_uses["tool_abc"].name, "Bash");
    }

    #[test]
    fn detects_file_churn() {
        let mut state = make_state();
        let block = serde_json::json!({
            "type": "tool_use",
            "id": "t1",
            "name": "Edit",
            "input": { "file_path": "test.rs", "old_string": "a", "new_string": "b" }
        });
        for _ in 0..9 {
            let issues = check_tool_use_for_issues(10, &block, &mut state);
            assert!(issues.is_empty());
        }
        let issues = check_tool_use_for_issues(10, &block, &mut state);
        assert_eq!(issues.len(), 1);
        assert!(issues[0].summary.contains("10 times"));
    }

    #[test]
    fn classify_line_parses_text_block() {
        let mut state = make_state();
        let line = serde_json::json!({
            "timestamp": "2025-01-01T00:00:00Z",
            "message": {
                "role": "user",
                "content": [{ "type": "text", "text": "stop guessing!" }]
            }
        });
        let issues = classify_line(0, &serde_json::to_string(&line).unwrap(), &mut state);
        assert!(!issues.is_empty());
        assert_eq!(
            state.session_start_timestamp.as_deref(),
            Some("2025-01-01T00:00:00Z")
        );
    }

    #[test]
    fn classify_line_skips_invalid_json() {
        let mut state = make_state();
        let issues = classify_line(0, "not json at all", &mut state);
        assert!(issues.is_empty());
    }

    #[test]
    fn classify_line_deduplicates() {
        let mut state = make_state();
        let line = serde_json::json!({
            "message": {
                "role": "user",
                "content": [{ "type": "text", "text": "stop guessing!" }]
            }
        });
        let raw = serde_json::to_string(&line).unwrap();
        let first = classify_line(0, &raw, &mut state);
        let second = classify_line(1, &raw, &mut state);
        assert!(!first.is_empty());
        assert!(second.is_empty(), "duplicate should be filtered");
    }

    #[test]
    fn classify_line_correlates_tool_result() {
        let mut state = make_state();
        let tool_use_line = serde_json::json!({
            "message": {
                "role": "assistant",
                "content": [{
                    "type": "tool_use",
                    "id": "tool_123",
                    "name": "Bash",
                    "input": { "command": "cargo build" }
                }]
            }
        });
        classify_line(
            0,
            &serde_json::to_string(&tool_use_line).unwrap(),
            &mut state,
        );

        let tool_result_line = serde_json::json!({
            "message": {
                "role": "user",
                "content": [{
                    "type": "tool_result",
                    "tool_use_id": "tool_123",
                    "content": [{ "type": "text", "text": "error[E0308]: mismatched types" }]
                }]
            }
        });
        let issues = classify_line(
            1,
            &serde_json::to_string(&tool_result_line).unwrap(),
            &mut state,
        );
        assert!(
            issues
                .iter()
                .any(|i| i.category == IssueCategory::BuildError)
        );
    }

    #[test]
    fn classify_line_string_content() {
        let mut state = make_state();
        let line = serde_json::json!({
            "message": {
                "role": "user",
                "content": "stop guessing and read it again!"
            }
        });
        let issues = classify_line(0, &serde_json::to_string(&line).unwrap(), &mut state);
        assert!(!issues.is_empty());
    }

    #[test]
    fn build_error_skipped_when_cli_error_matched() {
        // Text that matches both CLI error and build error patterns.
        // Build error should be suppressed because CLI error comes first.
        let issues = check_text_for_issues(
            10,
            "user",
            "harness: error: unresolved import cannot find value",
            Some("Bash"),
        );
        assert!(issues.iter().any(|i| i.category == IssueCategory::CliError));
        assert!(
            !issues
                .iter()
                .any(|i| i.category == IssueCategory::BuildError)
        );
    }

    #[test]
    fn env_misconfiguration_uses_pattern_array() {
        // Verify that env misconfiguration check responds to signals from
        // the patterns::ENV_MISCONFIGURATION_SIGNALS array.
        let issues = check_text_for_issues(10, "user", "CLAUDE_SESSION_ID=unset", Some("Bash"));
        assert!(
            issues
                .iter()
                .any(|i| i.category == IssueCategory::DataIntegrity)
        );
    }

    #[test]
    fn details_truncated_at_construction() {
        let long_text = "x".repeat(5000);
        let input = format!("harness: error: {long_text}");
        let issues = check_text_for_issues(10, "user", &input, Some("Bash"));
        assert!(!issues.is_empty());
        // Details should be capped by truncate_details (2000 chars).
        assert!(issues[0].details.len() <= 2001);
    }

    #[test]
    fn rule_table_has_expected_count() {
        assert_eq!(TEXT_RULES.len(), 15);
    }
}
