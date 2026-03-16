use super::issue_builder::issue;
use super::{AGENT_NAME_REGEX, EXIT_CODE_REGEX, TextCheckContext, should_emit};
use crate::commands::observe::patterns;
use crate::commands::observe::types::{Issue, IssueCategory};

/// Check for KSA hook codes in Bash output.
/// Caller guarantees: `source_tool` == Bash.
pub(super) fn check_ksa_codes(context: &mut TextCheckContext<'_>, issues: &mut Vec<Issue>) {
    for code in patterns::KSA_CODES {
        if context.lower.contains(code) {
            let display_code = code.to_uppercase();
            let summary = format!("Harness hook code {display_code} triggered");
            if !should_emit(IssueCategory::HookFailure, &summary, context.state) {
                break;
            }
            issues.push(issue!(
                context.line_number,
                context.role,
                context.text,
                HookFailure,
                Medium,
                summary,
                fixable: true,
                fix_hint: format!("Check hook logic for {display_code}"),
            ));
            break;
        }
    }
}

/// Check for harness command failures with non-zero exit codes.
/// Caller guarantees: `source_tool` == Bash.
pub(super) fn check_exit_code_issues(context: &mut TextCheckContext<'_>, issues: &mut Vec<Issue>) {
    let is_harness_operation = patterns::HARNESS_OPERATION_KEYWORDS
        .iter()
        .any(|keyword| context.lower.contains(keyword));

    let Some(captures) = EXIT_CODE_REGEX.captures(context.lower) else {
        return;
    };

    let code_str = captures
        .get(1)
        .or_else(|| captures.get(2))
        .map_or("0", |m| m.as_str());
    let exit_code: u32 = code_str.parse().unwrap_or(0);

    if exit_code == 0
        || context
            .matched_categories
            .contains(&IssueCategory::BuildError)
        || context
            .matched_categories
            .contains(&IssueCategory::CliError)
    {
        return;
    }

    let is_harness_authoring =
        context.lower.contains("harness") && context.lower.contains("authoring");

    if is_harness_operation {
        let summary = format!("Manifest operation failed at runtime (exit {exit_code}) - possible product bug");
        if should_emit(IssueCategory::DataIntegrity, &summary, context.state) {
            issues.push(issue!(
                context.line_number,
                context.role,
                context.text,
                DataIntegrity,
                Medium,
                summary,
                fixable: true,
                fix_hint: "Manifest preflight/apply/validate failed. Could be a suite error OR a product bug. \
                           Investigate whether the Go validator accepts what the CRD rejects.",
            ));
        }
    } else if is_harness_authoring {
        let summary = format!("Harness authoring command failed (exit {exit_code})");
        if should_emit(IssueCategory::WorkflowError, &summary, context.state) {
            issues.push(issue!(
                context.line_number,
                context.role,
                context.text,
                WorkflowError,
                Medium,
                summary,
                fixable: true,
                fix_hint:
                    "Harness authoring command returned non-zero - check payload or arguments",
            ));
        }
    } else if exit_code != 1 {
        let summary = format!("Non-zero exit code {exit_code}");
        if should_emit(IssueCategory::SubagentIssue, &summary, context.state) {
            issues.push(issue!(
                context.line_number,
                context.role,
                context.text,
                SubagentIssue,
                Low,
                summary,
                fix_hint: format!("Command exited with code {exit_code}"),
            ));
        }
    }
}

/// Check for subagent permission failures in user-role text.
/// Caller guarantees: role == User, `source_tool` == None.
pub(super) fn check_permission_failures(
    context: &mut TextCheckContext<'_>,
    issues: &mut Vec<Issue>,
) {
    if !patterns::PERMISSION_SIGNALS
        .iter()
        .any(|signal| context.lower.contains(signal))
    {
        return;
    }
    let agent_name = AGENT_NAME_REGEX
        .captures(context.text)
        .and_then(|c| c.get(1))
        .map_or("unknown", |m| m.as_str());
    let summary = format!("Subagent '{agent_name}' blocked by missing permissions");
    if !should_emit(IssueCategory::SubagentIssue, &summary, context.state) {
        return;
    }
    issues.push(issue!(
        context.line_number,
        context.role,
        context.text,
        SubagentIssue,
        Medium,
        summary,
        fixable: true,
        fix_hint: "Subagent needs permissionMode dontAsk or mode auto for Bash/Write",
    ));
}

/// Check for subagent save failures in assistant text.
/// Caller guarantees: role == Assistant, `source_tool` == None.
pub(super) fn check_save_failures(context: &mut TextCheckContext<'_>, issues: &mut Vec<Issue>) {
    if !patterns::SAVE_FAILURE_SIGNALS
        .iter()
        .any(|signal| context.lower.contains(signal))
    {
        return;
    }
    let text_context: String = context.text.chars().take(40).collect();
    let text_context = text_context.replace('\n', " ");
    let summary = format!("Subagent manual recovery: {text_context}");
    if !should_emit(IssueCategory::SubagentIssue, &summary, context.state) {
        return;
    }
    issues.push(issue!(
        context.line_number,
        context.role,
        context.text,
        SubagentIssue,
        Medium,
        summary,
        fixable: true,
        fix_hint: "Subagent lacks write permissions or hit a harness CLI error during save",
    ));
}

/// Check for manual payload recovery patterns.
/// Caller guarantees: role == Assistant, `source_tool` == None.
pub(super) fn check_payload_recovery(context: &mut TextCheckContext<'_>, issues: &mut Vec<Issue>) {
    let has_grep = context.lower.contains("grep");
    let has_target = context.lower.contains("output")
        || context.lower.contains("transcript")
        || context.lower.contains("payload");
    let has_recovery = context.lower.contains("found the full payload")
        || context.lower.contains("extract and save")
        || context.lower.contains("grab its");
    if has_grep && has_target && has_recovery {
        let summary = "Manual payload recovery from subagent output";
        if !should_emit(IssueCategory::SubagentIssue, summary, context.state) {
            return;
        }
        issues.push(issue!(
            context.line_number,
            context.role,
            context.text,
            SubagentIssue,
            Medium,
            summary,
            fixable: true,
            fix_hint:
                "Subagent should save its own payload - manual grep recovery is a workflow failure",
        ));
    }
}

/// Check for misconfigured environment variables in Bash output.
/// Caller guarantees: `source_tool` == Bash.
pub(super) fn check_env_misconfiguration(
    context: &mut TextCheckContext<'_>,
    issues: &mut Vec<Issue>,
) {
    for signal in patterns::ENV_MISCONFIGURATION_SIGNALS {
        if !context.lower.contains(signal) {
            continue;
        }
        if signal.contains("claude_session_id") {
            let summary = "CLAUDE_SESSION_ID is unset - harness cannot resolve session context";
            if !should_emit(IssueCategory::DataIntegrity, summary, context.state) {
                continue;
            }
            issues.push(issue!(
                context.line_number,
                context.role,
                context.text,
                DataIntegrity,
                Critical,
                summary,
                fixable: true,
                fix_target: "src/context.rs",
                fix_hint: "Session ID env var not set. Harness init and runner-state \
                           cannot find the context directory without it.",
            ));
        } else if signal.contains("kubeconfig") {
            let summary = "KUBECONFIG is empty - cluster commands will hit default context";
            if !should_emit(IssueCategory::SkillBehavior, summary, context.state) {
                continue;
            }
            issues.push(issue!(
                context.line_number,
                context.role,
                context.text,
                SkillBehavior,
                Critical,
                summary,
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
/// Caller guarantees: role == Assistant, `source_tool` == None.
pub(super) fn check_incomplete_writer(context: &mut TextCheckContext<'_>, issues: &mut Vec<Issue>) {
    if !patterns::INCOMPLETE_WRITER_SIGNALS
        .iter()
        .any(|signal| context.lower.contains(signal))
    {
        return;
    }
    let summary = "Writer subagent produced incomplete output";
    if !should_emit(IssueCategory::SubagentIssue, summary, context.state) {
        return;
    }
    issues.push(issue!(
        context.line_number,
        context.role,
        context.text,
        SubagentIssue,
        Medium,
        summary,
        fixable: true,
        fix_hint: "Writer agent failed to save all files - check permissions and payload size",
    ));
}

/// Check for user frustration signals in human text.
/// Caller guarantees: role == User, `source_tool` == None.
pub(super) fn check_user_frustration(context: &mut TextCheckContext<'_>, issues: &mut Vec<Issue>) {
    if context.text.len() >= 2000 {
        return;
    }
    let exclamation_count = context.text.chars().filter(|&c| c == '!').count();
    let has_signal = patterns::USER_FRUSTRATION_SIGNALS
        .iter()
        .any(|signal| context.lower.contains(signal));

    if exclamation_count >= 4 || has_signal {
        let summary = "User frustration signal detected";
        if !should_emit(IssueCategory::UserFrustration, summary, context.state) {
            return;
        }
        issues.push(issue!(
            context.line_number,
            context.role,
            context.text,
            UserFrustration,
            Medium,
            summary,
            fix_hint: "Review what happened before this - likely a UX issue",
        ));
    }
}
