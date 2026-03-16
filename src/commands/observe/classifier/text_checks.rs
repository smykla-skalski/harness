use super::emitter::{Guidance, IssueBlueprint};
use super::{AGENT_NAME_REGEX, EXIT_CODE_REGEX, TextCheckContext};
use crate::commands::observe::patterns;
use crate::commands::observe::types::{Issue, IssueCategory, IssueCode, IssueSeverity};

/// Check for KSA hook codes in Bash output.
/// Caller guarantees: `source_tool` == Bash.
pub(super) fn check_ksa_codes(context: &mut TextCheckContext<'_>, issues: &mut Vec<Issue>) {
    for code in patterns::KSA_CODES {
        if context.lower.contains(code) {
            let display_code = code.to_uppercase();
            let summary = format!("Harness hook code {display_code} triggered");
            let blueprint = IssueBlueprint::new(
                IssueCode::HarnessHookCodeTriggered,
                IssueCategory::HookFailure,
                IssueSeverity::Medium,
                summary,
            )
            .with_fingerprint(display_code.clone())
            .with_guidance(Guidance::fix_hint(format!(
                "Check hook logic for {display_code}"
            )));
            context.emit_current(issues, blueprint);
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
        let summary = format!(
            "Manifest operation failed at runtime (exit {exit_code}) - possible product bug"
        );
        let blueprint = IssueBlueprint::new(
            IssueCode::ManifestRuntimeFailure,
            IssueCategory::DataIntegrity,
            IssueSeverity::Medium,
            summary,
        )
        .with_fingerprint("manifest_runtime_failure")
        .with_guidance(Guidance::fix_hint(
            "Manifest preflight/apply/validate failed. Could be a suite error OR a product bug. \
             Investigate whether the Go validator accepts what the CRD rejects.",
        ));
        context.emit_current(issues, blueprint);
    } else if is_harness_authoring {
        let summary = format!("Harness authoring command failed (exit {exit_code})");
        let blueprint = IssueBlueprint::new(
            IssueCode::HarnessAuthoringCommandFailure,
            IssueCategory::WorkflowError,
            IssueSeverity::Medium,
            summary,
        )
        .with_fingerprint("harness_authoring_failure")
        .with_guidance(Guidance::fix_hint(
            "Harness authoring command returned non-zero - check payload or arguments",
        ));
        context.emit_current(issues, blueprint);
    } else if exit_code != 1 {
        let summary = format!("Non-zero exit code {exit_code}");
        let blueprint = IssueBlueprint::new(
            IssueCode::NonZeroExitCode,
            IssueCategory::SubagentIssue,
            IssueSeverity::Low,
            summary,
        )
        .with_fingerprint("non_zero_exit_code")
        .with_guidance(Guidance::advisory(format!(
            "Command exited with code {exit_code}"
        )));
        context.emit_current(issues, blueprint);
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
    let blueprint = IssueBlueprint::new(
        IssueCode::SubagentPermissionFailure,
        IssueCategory::SubagentIssue,
        IssueSeverity::Medium,
        summary,
    )
    .with_fingerprint(agent_name)
    .with_guidance(Guidance::fix_hint(
        "Subagent needs permissionMode dontAsk or mode auto for Bash/Write",
    ));
    context.emit_current(issues, blueprint);
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
    let blueprint = IssueBlueprint::new(
        IssueCode::SubagentManualRecovery,
        IssueCategory::SubagentIssue,
        IssueSeverity::Medium,
        summary,
    )
    .with_guidance(Guidance::fix_hint(
        "Subagent lacks write permissions or hit a harness CLI error during save",
    ));
    context.emit_current(issues, blueprint);
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
        let blueprint = IssueBlueprint::new(
            IssueCode::ManualPayloadRecovery,
            IssueCategory::SubagentIssue,
            IssueSeverity::Medium,
            "Manual payload recovery from subagent output",
        )
        .with_guidance(Guidance::fix_hint(
            "Subagent should save its own payload - manual grep recovery is a workflow failure",
        ));
        context.emit_current(issues, blueprint);
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
            let blueprint = IssueBlueprint::new(
                IssueCode::MissingClaudeSessionId,
                IssueCategory::DataIntegrity,
                IssueSeverity::Critical,
                "CLAUDE_SESSION_ID is unset - harness cannot resolve session context",
            )
            .with_guidance(Guidance::fix_target_hint(
                "src/context.rs",
                "Session ID env var not set. Harness init and runner-state \
                 cannot find the context directory without it.",
            ));
            context.emit_current(issues, blueprint);
        } else if signal.contains("kubeconfig") {
            let blueprint = IssueBlueprint::new(
                IssueCode::EmptyKubeconfig,
                IssueCategory::SkillBehavior,
                IssueSeverity::Critical,
                "KUBECONFIG is empty - cluster commands will hit default context",
            )
            .with_guidance(Guidance::fix_target_hint(
                "skills/run/SKILL.md",
                "harness cluster should set KUBECONFIG to the k3d cluster config. \
                 Without it, kubectl defaults to ~/.kube/config which may point \
                 to a corporate cluster.",
            ));
            context.emit_current(issues, blueprint);
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
    let blueprint = IssueBlueprint::new(
        IssueCode::IncompleteWriterOutput,
        IssueCategory::SubagentIssue,
        IssueSeverity::Medium,
        "Writer subagent produced incomplete output",
    )
    .with_guidance(Guidance::fix_hint(
        "Writer agent failed to save all files - check permissions and payload size",
    ));
    context.emit_current(issues, blueprint);
}

/// Check for assistant text admitting harness infrastructure problems.
/// Caller guarantees: role == Assistant, `source_tool` == None.
pub(super) fn check_harness_infrastructure(
    context: &mut TextCheckContext<'_>,
    issues: &mut Vec<Issue>,
) {
    // Direct phrases: "harness infrastructure issue", "harness bug"
    let direct_match = patterns::HARNESS_INFRASTRUCTURE_SIGNALS
        .iter()
        .any(|signal| context.lower.contains(signal));

    // Compound: harness subsystem keyword + failure word
    let subsystem_match = patterns::HARNESS_SUBSYSTEM_KEYWORDS
        .iter()
        .any(|keyword| context.lower.contains(keyword))
        && patterns::HARNESS_SUBSYSTEM_FAILURE_WORDS
            .iter()
            .any(|word| context.lower.contains(word));

    if direct_match || subsystem_match {
        let blueprint = IssueBlueprint::new(
            IssueCode::HarnessInfrastructureMisconfiguration,
            IssueCategory::WorkflowError,
            IssueSeverity::Critical,
            "Harness infrastructure misconfiguration detected",
        )
        .with_fingerprint("harness_infrastructure_misconfiguration")
        .with_guidance(Guidance::fix_hint(
            "Fix the harness bootstrap/cluster command to handle this automatically",
        ));
        context.emit_current(issues, blueprint);
    }
}

/// Check for assistant text acknowledging missing env vars or connections.
/// Caller guarantees: role == Assistant, `source_tool` == None.
pub(super) fn check_missing_connection_or_env_var(
    context: &mut TextCheckContext<'_>,
    issues: &mut Vec<Issue>,
) {
    // "lack"/"missing" + env var name
    let env_var_match = patterns::MISSING_CONFIG_ABSENCE_WORDS
        .iter()
        .any(|word| context.lower.contains(word))
        && patterns::MISSING_CONFIG_ENV_VARS
            .iter()
            .any(|variable| context.lower.contains(variable));

    // "not established" + "kds"/"connection"
    let connection_match = context.lower.contains("not established")
        && patterns::MISSING_CONNECTION_COMPONENTS
            .iter()
            .any(|component| context.lower.contains(component));

    if env_var_match || connection_match {
        let blueprint = IssueBlueprint::new(
            IssueCode::MissingConnectionOrEnvVar,
            IssueCategory::DataIntegrity,
            IssueSeverity::Medium,
            "Missing configuration or connection acknowledged by assistant",
        )
        .with_fingerprint("missing_connection_or_env_var")
        .with_guidance(Guidance::advisory(
            "Could be a harness bootstrap gap or a product bug - investigate which layer dropped it",
        ));
        context.emit_current(issues, blueprint);
    }
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
        let blueprint = IssueBlueprint::new(
            IssueCode::UserFrustrationDetected,
            IssueCategory::UserFrustration,
            IssueSeverity::Medium,
            "User frustration signal detected",
        )
        .with_guidance(Guidance::advisory(
            "Review what happened before this - likely a UX issue",
        ));
        context.emit_current(issues, blueprint);
    }
}
