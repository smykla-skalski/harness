use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

use super::patterns;
use super::tool_result_text;
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
    let lower = text.to_lowercase();
    let trimmed = lower.trim();
    trimmed.starts_with("kuma test harness")
        || (trimmed.starts_with("usage: harness") && !trimmed.contains("error:"))
        || trimmed.starts_with("handle session start hook\n\nusage:")
}

/// Detect compaction context injection.
fn is_compaction_summary(text: &str) -> bool {
    text.to_lowercase()
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
    let summary_prefix: String = issue.summary.chars().take(80).collect();
    let key = (issue.category.to_string(), summary_prefix);
    if state.seen_issues.contains(&key) {
        return true;
    }
    state.seen_issues.insert(key);
    false
}

/// Check text content for hook denial issues.
fn check_hook_denials(
    line_num: usize,
    role: &str,
    text: &str,
    lower: &str,
    issues: &mut Vec<Issue>,
) {
    if lower.contains("denied this tool") || lower.contains("blocked by hook") {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::HookFailure,
            severity: IssueSeverity::Medium,
            summary: "Hook denied a tool call".into(),
            details: text.to_string(),
            source_role: role.to_string(),
            fixable: false,
            fix_target: None,
            fix_hint: None,
        });
    }
}

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
            issues.push(Issue {
                line: line_num,
                category: IssueCategory::HookFailure,
                severity: IssueSeverity::Medium,
                summary: format!("Harness hook code {display_code} triggered"),
                details: text.to_string(),
                source_role: role.to_string(),
                fixable: true,
                fix_target: None,
                fix_hint: Some(format!("Check hook logic for {display_code}")),
            });
            break;
        }
    }
}

/// Check for CLI errors in Bash output.
fn check_cli_errors(
    line_num: usize,
    role: &str,
    text: &str,
    lower: &str,
    source_tool: Option<&str>,
    issues: &mut Vec<Issue>,
    matched_categories: &mut Vec<IssueCategory>,
) {
    if source_tool != Some("Bash") || !lower.contains("harness") {
        return;
    }
    for pattern in patterns::CLI_ERROR_PATTERNS {
        if lower.contains(pattern) {
            issues.push(Issue {
                line: line_num,
                category: IssueCategory::CliError,
                severity: IssueSeverity::Medium,
                summary: format!("Harness CLI error: {pattern}"),
                details: text.to_string(),
                source_role: role.to_string(),
                fixable: true,
                fix_target: Some("cli.rs".into()),
                fix_hint: None,
            });
            matched_categories.push(IssueCategory::CliError);
            break;
        }
    }
}

/// Check for tool usage errors.
fn check_tool_errors(
    line_num: usize,
    role: &str,
    text: &str,
    lower: &str,
    issues: &mut Vec<Issue>,
    matched_categories: &mut Vec<IssueCategory>,
) {
    for pattern in patterns::TOOL_ERROR_PATTERNS {
        if lower.contains(pattern) {
            issues.push(Issue {
                line: line_num,
                category: IssueCategory::ToolError,
                severity: IssueSeverity::Low,
                summary: format!("Tool usage error: {pattern}"),
                details: text.to_string(),
                source_role: role.to_string(),
                fixable: false,
                fix_target: None,
                fix_hint: Some("Model behavior - read before edit".into()),
            });
            matched_categories.push(IssueCategory::ToolError);
            break;
        }
    }
}

/// Check for build errors in Bash output.
fn check_build_errors(
    line_num: usize,
    role: &str,
    text: &str,
    lower: &str,
    source_tool: Option<&str>,
    issues: &mut Vec<Issue>,
    matched_categories: &[IssueCategory],
) {
    if matched_categories.contains(&IssueCategory::CliError) || source_tool != Some("Bash") {
        return;
    }
    for pattern in patterns::BUILD_ERROR_PATTERNS {
        if lower.contains(pattern) {
            issues.push(Issue {
                line: line_num,
                category: IssueCategory::BuildError,
                severity: IssueSeverity::Critical,
                summary: "Build or lint failure".into(),
                details: text.to_string(),
                source_role: role.to_string(),
                fixable: true,
                fix_target: None,
                fix_hint: Some("Fix the Rust code causing the failure".into()),
            });
            break;
        }
    }
}

/// Check for workflow state errors in Bash output.
fn check_workflow_errors(
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
    for pattern in patterns::WORKFLOW_ERROR_PATTERNS {
        if lower.contains(pattern) {
            issues.push(Issue {
                line: line_num,
                category: IssueCategory::WorkflowError,
                severity: IssueSeverity::Medium,
                summary: format!("Workflow state error: {pattern}"),
                details: text.to_string(),
                source_role: role.to_string(),
                fixable: true,
                fix_target: None,
                fix_hint: Some("Check workflow state machine logic".into()),
            });
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
    matched_categories: &[IssueCategory],
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
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::SkillBehavior,
            severity: IssueSeverity::Medium,
            summary: format!("Authored manifest failed at runtime (exit {exit_code})"),
            details: text.to_string(),
            source_role: role.to_string(),
            fixable: true,
            fix_target: Some("skills/new/SKILL.md".into()),
            fix_hint: Some(
                "suite:new produced manifests that fail preflight/apply/validate - check authoring validation"
                    .into(),
            ),
        });
    } else if is_harness_authoring {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::WorkflowError,
            severity: IssueSeverity::Medium,
            summary: format!("Harness authoring command failed (exit {exit_code})"),
            details: text.to_string(),
            source_role: role.to_string(),
            fixable: true,
            fix_target: None,
            fix_hint: Some(
                "Harness authoring command returned non-zero - check payload or arguments".into(),
            ),
        });
    } else if exit_code != 1 {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::SubagentIssue,
            severity: IssueSeverity::Low,
            summary: format!("Non-zero exit code {exit_code}"),
            details: text.to_string(),
            source_role: role.to_string(),
            fixable: false,
            fix_target: None,
            fix_hint: Some(format!("Command exited with code {exit_code}")),
        });
    }
}

/// Check for pod/container failures from Bash output.
fn check_pod_failures(
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
    if patterns::POD_FAILURE_SIGNALS
        .iter()
        .any(|signal| lower.contains(signal))
    {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::SkillBehavior,
            severity: IssueSeverity::Critical,
            summary: "Authored manifest caused runtime failure".into(),
            details: text.to_string(),
            source_role: role.to_string(),
            fixable: true,
            fix_target: Some("skills/new/SKILL.md".into()),
            fix_hint: Some("suite:new produced a manifest with outdated or invalid config".into()),
        });
    }
}

/// Check for auth flow triggers in Bash output.
fn check_auth_flow(
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
    if patterns::AUTH_SIGNALS
        .iter()
        .any(|signal| lower.contains(signal))
    {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::UnexpectedBehavior,
            severity: IssueSeverity::Critical,
            summary: "OAuth/auth flow triggered - command tried to reach a real cluster".into(),
            details: text.to_string(),
            source_role: role.to_string(),
            fixable: true,
            fix_target: None,
            fix_hint: Some(
                "Command attempted cluster auth. Block the binary in guard-bash or use local-only validation"
                    .into(),
            ),
        });
    }
}

/// Check for direct `kubectl-validate` usage in Bash output.
fn check_kubectl_validate_direct(
    line_num: usize,
    role: &str,
    text: &str,
    lower: &str,
    source_tool: Option<&str>,
    issues: &mut Vec<Issue>,
) {
    if source_tool == Some("Bash") && lower.contains("kubectl-validate") {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::SkillBehavior,
            severity: IssueSeverity::Critical,
            summary: "kubectl-validate used directly instead of harness authoring-validate".into(),
            details: text.to_string(),
            source_role: role.to_string(),
            fixable: true,
            fix_target: Some("skills/new/SKILL.md".into()),
            fix_hint: Some(
                "Use harness authoring-validate, not kubectl-validate. kubectl-validate can reach real clusters."
                    .into(),
            ),
        });
    }
}

/// Check for shell alias interference (cp -> rsync).
fn check_alias_interference(
    line_num: usize,
    role: &str,
    text: &str,
    lower: &str,
    source_tool: Option<&str>,
    issues: &mut Vec<Issue>,
) {
    if source_tool == Some("Bash") && lower.contains("rsync") {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::UnexpectedBehavior,
            severity: IssueSeverity::Medium,
            summary: "Shell alias interference - rsync in cp output".into(),
            details: text.to_string(),
            source_role: role.to_string(),
            fixable: false,
            fix_target: None,
            fix_hint: Some("Shell alias resolved cp to rsync - use /bin/cp".into()),
        });
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
    issues.push(Issue {
        line: line_num,
        category: IssueCategory::SubagentIssue,
        severity: IssueSeverity::Medium,
        summary: format!("Subagent '{agent_name}' blocked by missing permissions"),
        details: text.to_string(),
        source_role: role.to_string(),
        fixable: true,
        fix_target: None,
        fix_hint: Some("Subagent needs permissionMode dontAsk or mode auto for Bash/Write".into()),
    });
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
    issues.push(Issue {
        line: line_num,
        category: IssueCategory::SubagentIssue,
        severity: IssueSeverity::Medium,
        summary: format!("Subagent manual recovery: {context}"),
        details: text.to_string(),
        source_role: role.to_string(),
        fixable: true,
        fix_target: None,
        fix_hint: Some(
            "Subagent lacks write permissions or hit a harness CLI error during save".into(),
        ),
    });
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
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::SubagentIssue,
            severity: IssueSeverity::Medium,
            summary: "Manual payload recovery from subagent output".into(),
            details: text.to_string(),
            source_role: role.to_string(),
            fixable: true,
            fix_target: None,
            fix_hint: Some(
                "Subagent should save its own payload - manual grep recovery is a workflow failure"
                    .into(),
            ),
        });
    }
}

/// Check for payload corruption (XML tags around JSON).
fn check_payload_corruption(
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
    if lower.contains("<json>") || lower.contains("</json>") {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::DataIntegrity,
            severity: IssueSeverity::Medium,
            summary: "Payload wrapped in <json> tags - data corruption from subagent".into(),
            details: text.to_string(),
            source_role: role.to_string(),
            fixable: true,
            fix_target: None,
            fix_hint: Some(
                "Subagent output contains XML-style tags around JSON - strip before parsing".into(),
            ),
        });
    }
}

/// Check for Python tracebacks in Bash output.
fn check_python_tracebacks(
    line_num: usize,
    role: &str,
    text: &str,
    lower: &str,
    source_tool: Option<&str>,
    issues: &mut Vec<Issue>,
) {
    if source_tool == Some("Bash") && lower.contains("traceback (most recent call last)") {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::BuildError,
            severity: IssueSeverity::Medium,
            summary: "Python traceback in command output".into(),
            details: text.to_string(),
            source_role: role.to_string(),
            fixable: true,
            fix_target: None,
            fix_hint: Some("Python script failed - check input data or script logic".into()),
        });
    }
}

/// Check for suite deviation signals in assistant text.
fn check_deviation_signals(
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
    if patterns::DEVIATION_SIGNALS
        .iter()
        .any(|signal| lower.contains(signal))
    {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::SkillBehavior,
            severity: IssueSeverity::Critical,
            summary:
                "Suite deviation - baselines/manifests not distributed to all required clusters"
                    .into(),
            details: text.to_string(),
            source_role: role.to_string(),
            fixable: true,
            fix_target: Some("skills/new/SKILL.md".into()),
            fix_hint: Some(
                "suite:new must distribute baselines to all clusters in multi-zone profiles".into(),
            ),
        });
    }
}

/// Check for release kumactl version in Bash output.
///
/// When a run has `--repo-root` pointing to a worktree, `kumactl version`
/// should return a dev build, not a release like "Kuma 2.13.2". A release
/// version means the system binary is being used instead of the worktree build.
fn check_release_kumactl_version(
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
    if patterns::RELEASE_VERSION_SIGNALS
        .iter()
        .any(|signal| lower.contains(signal))
    {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::SkillBehavior,
            severity: IssueSeverity::Critical,
            summary: "Release kumactl binary used instead of worktree build".into(),
            details: text.to_string(),
            source_role: role.to_string(),
            fixable: true,
            fix_target: Some("skills/run/SKILL.md".into()),
            fix_hint: Some(
                "kumactl version shows a release build. The run should use \
                 kumactl built from the worktree under test, not the system binary."
                    .into(),
            ),
        });
    }
}

/// Check for python usage in Bash commands.
fn check_python_usage(
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
    if patterns::PYTHON_USAGE_SIGNALS
        .iter()
        .any(|signal| lower.contains(signal))
    {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::UnexpectedBehavior,
            severity: IssueSeverity::Medium,
            summary: "Python used in Bash command - agents should never need python".into(),
            details: text.to_string(),
            source_role: role.to_string(),
            fixable: true,
            fix_target: None,
            fix_hint: Some(
                "Use harness commands or shell builtins instead of python one-liners".into(),
            ),
        });
    }
}

/// Check for stale run pointer in context output.
fn check_stale_run_pointer(
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
    if !lower.contains("current-run.json") {
        return;
    }
    // Detect when current-run.json content references a different suite than expected
    if lower.contains("motb-core") && !lower.contains("motb-compliance") {
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::DataIntegrity,
            severity: IssueSeverity::Critical,
            summary: "Stale run pointer - current-run.json points to wrong run".into(),
            details: text.to_string(),
            source_role: role.to_string(),
            fixable: true,
            fix_target: Some("src/context.rs".into()),
            fix_hint: Some(
                "harness init should update the context pointer. This is a harness bug.".into(),
            ),
        });
    }
}

/// Check for direct writes to harness-managed files via Write/Edit tools.
fn check_managed_file_writes(
    line_num: usize,
    _name: &str,
    input: &Value,
    issues: &mut Vec<Issue>,
) {
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
        issues.push(Issue {
            line: line_num,
            category: IssueCategory::UserFrustration,
            severity: IssueSeverity::Medium,
            summary: "User frustration signal detected".into(),
            details: text.to_string(),
            source_role: role.to_string(),
            fixable: false,
            fix_target: None,
            fix_hint: Some("Review what happened before this - likely a UX issue".into()),
        });
    }
}

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
    _state: &ScanState,
) -> Vec<Issue> {
    if source_tool == Some("Read") || is_file_content(text) {
        return Vec::new();
    }
    if is_help_output(text) || is_compaction_summary(text) || is_skill_injection(text) {
        return Vec::new();
    }

    let lower = text.to_lowercase();
    let mut issues = Vec::new();
    let mut matched_categories: Vec<IssueCategory> = Vec::new();

    check_hook_denials(line_num, role, text, &lower, &mut issues);
    check_ksa_codes(line_num, role, text, &lower, source_tool, &mut issues);
    check_cli_errors(
        line_num,
        role,
        text,
        &lower,
        source_tool,
        &mut issues,
        &mut matched_categories,
    );
    check_tool_errors(
        line_num,
        role,
        text,
        &lower,
        &mut issues,
        &mut matched_categories,
    );
    check_build_errors(
        line_num,
        role,
        text,
        &lower,
        source_tool,
        &mut issues,
        &matched_categories,
    );
    check_workflow_errors(line_num, role, text, &lower, source_tool, &mut issues);
    check_exit_code_issues(
        line_num,
        role,
        text,
        &lower,
        source_tool,
        &mut issues,
        &matched_categories,
    );
    check_pod_failures(line_num, role, text, &lower, source_tool, &mut issues);
    check_auth_flow(line_num, role, text, &lower, source_tool, &mut issues);
    check_kubectl_validate_direct(line_num, role, text, &lower, source_tool, &mut issues);
    check_alias_interference(line_num, role, text, &lower, source_tool, &mut issues);
    check_permission_failures(line_num, role, text, &lower, source_tool, &mut issues);
    check_save_failures(line_num, role, text, &lower, source_tool, &mut issues);
    check_payload_recovery(line_num, role, text, &lower, source_tool, &mut issues);
    check_payload_corruption(line_num, role, text, &lower, source_tool, &mut issues);
    check_python_tracebacks(line_num, role, text, &lower, source_tool, &mut issues);
    check_deviation_signals(line_num, role, text, &lower, source_tool, &mut issues);
    check_release_kumactl_version(line_num, role, text, &lower, source_tool, &mut issues);
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
    }

    // Record `tool_use` for correlating with `tool_result`
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
fn check_question_deviations(
    line_num: usize,
    question_text: &str,
    question_lower: &str,
    header: &str,
    options: Option<&Vec<Value>>,
    issues: &mut Vec<Issue>,
) {
    let mut all_text_parts = vec![header.to_lowercase(), question_lower.to_string()];
    if let Some(opts) = options {
        for opt in opts {
            if let Some(label) = opt["label"].as_str() {
                all_text_parts.push(label.to_lowercase());
            }
            if let Some(desc) = opt["description"].as_str() {
                all_text_parts.push(desc.to_lowercase());
            }
            if let Some(s) = opt.as_str() {
                all_text_parts.push(s.to_lowercase());
            }
        }
    }
    let all_text = all_text_parts.join(" ");

    if patterns::QUESTION_DEVIATION_SIGNALS
        .iter()
        .any(|signal| all_text.contains(signal))
    {
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
        issues.extend(check_text_for_issues(line_num, role, text, None, state));
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
                    issues.extend(check_text_for_issues(line_num, role, text, None, state));
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
                        state,
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
        let state = make_state();
        let issues = check_text_for_issues(
            10,
            "user",
            "The system denied this tool call because it violates policy",
            None,
            &state,
        );
        assert_eq!(issues.len(), 1);
        assert_eq!(issues[0].category, IssueCategory::HookFailure);
    }

    #[test]
    fn detects_ksa_code_in_bash() {
        let state = make_state();
        let issues = check_text_for_issues(
            20,
            "user",
            "ERROR [KSA001] Write path is outside the suite:new surface",
            Some("Bash"),
            &state,
        );
        assert!(
            issues
                .iter()
                .any(|i| i.category == IssueCategory::HookFailure)
        );
    }

    #[test]
    fn skips_ksa_code_not_bash() {
        let state = make_state();
        let issues = check_text_for_issues(
            20,
            "user",
            "ERROR [KSA001] Write path is outside",
            None,
            &state,
        );
        assert!(!issues.iter().any(|i| i.summary.contains("KSA001")));
    }

    #[test]
    fn detects_cli_error() {
        let state = make_state();
        let issues = check_text_for_issues(
            30,
            "user",
            "harness: error: unrecognized arguments --bad-flag",
            Some("Bash"),
            &state,
        );
        assert!(issues.iter().any(|i| i.category == IssueCategory::CliError));
    }

    #[test]
    fn detects_tool_error() {
        let state = make_state();
        let issues = check_text_for_issues(
            40,
            "user",
            "Error: file has not been read yet. Read the file first.",
            None,
            &state,
        );
        assert!(
            issues
                .iter()
                .any(|i| i.category == IssueCategory::ToolError)
        );
    }

    #[test]
    fn detects_build_error() {
        let state = make_state();
        let issues = check_text_for_issues(
            50,
            "user",
            "error[E0308]: mismatched types\n  expected u32, found &str",
            Some("Bash"),
            &state,
        );
        assert!(
            issues
                .iter()
                .any(|i| i.category == IssueCategory::BuildError)
        );
    }

    #[test]
    fn detects_user_frustration() {
        let state = make_state();
        let issues =
            check_text_for_issues(60, "user", "stop guessing and read it again!", None, &state);
        assert!(
            issues
                .iter()
                .any(|i| i.category == IssueCategory::UserFrustration)
        );
    }

    #[test]
    fn skips_file_content() {
        let state = make_state();
        let text = "     1\u{2192}fn main() {\n     2\u{2192}    println!(\"error[E0308]\");\n     3\u{2192}}";
        let issues = check_text_for_issues(70, "user", text, None, &state);
        assert!(issues.is_empty());
    }

    #[test]
    fn skips_help_output() {
        let state = make_state();
        let issues = check_text_for_issues(
            80,
            "user",
            "Kuma test harness\n\nUsage: harness [COMMAND]",
            Some("Bash"),
            &state,
        );
        assert!(issues.is_empty());
    }

    #[test]
    fn skips_compaction_summary() {
        let state = make_state();
        let issues = check_text_for_issues(
            90,
            "user",
            "This session is being continued from a previous conversation. Here is context.",
            None,
            &state,
        );
        assert!(issues.is_empty());
    }

    #[test]
    fn detects_auth_flow() {
        let state = make_state();
        let issues = check_text_for_issues(
            100,
            "user",
            "Opening browser for authentication to your cluster",
            Some("Bash"),
            &state,
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
}
