use std::collections::HashSet;

use super::issue_builder::issue;
use super::{AGENT_NAME_REGEX, EXIT_CODE_REGEX};
use crate::commands::observe::patterns;
use crate::commands::observe::types::{Issue, IssueCategory, MessageRole, SourceTool};

/// Check for KSA hook codes in Bash output.
pub(super) fn check_ksa_codes(
    line_num: usize,
    role: MessageRole,
    text: &str,
    lower: &str,
    source_tool: Option<SourceTool>,
    issues: &mut Vec<Issue>,
) {
    if source_tool != Some(SourceTool::Bash) {
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
pub(super) fn check_exit_code_issues(
    line_num: usize,
    role: MessageRole,
    text: &str,
    lower: &str,
    source_tool: Option<SourceTool>,
    issues: &mut Vec<Issue>,
    matched_categories: &HashSet<IssueCategory>,
) {
    if source_tool != Some(SourceTool::Bash) {
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
pub(super) fn check_permission_failures(
    line_num: usize,
    role: MessageRole,
    text: &str,
    lower: &str,
    source_tool: Option<SourceTool>,
    issues: &mut Vec<Issue>,
) {
    if role != MessageRole::User || source_tool.is_some() {
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
pub(super) fn check_save_failures(
    line_num: usize,
    role: MessageRole,
    text: &str,
    lower: &str,
    source_tool: Option<SourceTool>,
    issues: &mut Vec<Issue>,
) {
    if role != MessageRole::Assistant || source_tool.is_some() {
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
pub(super) fn check_payload_recovery(
    line_num: usize,
    role: MessageRole,
    text: &str,
    lower: &str,
    source_tool: Option<SourceTool>,
    issues: &mut Vec<Issue>,
) {
    if role != MessageRole::Assistant || source_tool.is_some() {
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
pub(super) fn check_env_misconfiguration(
    line_num: usize,
    role: MessageRole,
    text: &str,
    lower: &str,
    source_tool: Option<SourceTool>,
    issues: &mut Vec<Issue>,
) {
    if source_tool != Some(SourceTool::Bash) {
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

/// Check for incomplete writer agent output in assistant text.
pub(super) fn check_incomplete_writer(
    line_num: usize,
    role: MessageRole,
    text: &str,
    lower: &str,
    source_tool: Option<SourceTool>,
    issues: &mut Vec<Issue>,
) {
    if role != MessageRole::Assistant || source_tool.is_some() {
        return;
    }
    if !patterns::INCOMPLETE_WRITER_SIGNALS
        .iter()
        .any(|signal| lower.contains(signal))
    {
        return;
    }
    issues.push(issue!(
        line_num,
        role,
        text,
        SubagentIssue,
        Medium,
        "Writer subagent produced incomplete output",
        fixable: true,
        fix_hint: "Writer agent failed to save all files - check permissions and payload size",
    ));
}

/// Check for user frustration signals in human text.
pub(super) fn check_user_frustration(
    line_num: usize,
    role: MessageRole,
    text: &str,
    lower: &str,
    source_tool: Option<SourceTool>,
    issues: &mut Vec<Issue>,
) {
    if role != MessageRole::User || source_tool.is_some() || text.len() >= 2000 {
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
