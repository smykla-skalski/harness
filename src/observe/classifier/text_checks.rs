use super::emitter::{Guidance, IssueBlueprint};
use super::{AGENT_NAME_REGEX, EXIT_CODE_REGEX, TextCheckContext};
use crate::observe::patterns;
use crate::observe::types::{Confidence, FixSafety, Issue, IssueCategory, IssueCode};

/// Check for KSA hook codes in Bash output.
/// Caller guarantees: `source_tool` == Bash.
pub(super) fn check_ksa_codes(context: &mut TextCheckContext<'_>, issues: &mut Vec<Issue>) {
    for code in patterns::KSA_CODES {
        if context.lower.contains(code) {
            let display_code = code.to_uppercase();
            let summary = format!("Harness hook code {display_code} triggered");
            let blueprint = IssueBlueprint::from_code(IssueCode::HarnessHookCodeTriggered, summary)
                .with_fingerprint(display_code.clone())
                .with_guidance(Guidance::fix_hint(format!(
                    "Check hook logic for {display_code}"
                )))
                .with_confidence(Confidence::High)
                .with_fix_safety(FixSafety::AutoFixSafe)
                .with_source_tool(context.source_tool);
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
        let blueprint = IssueBlueprint::from_code(IssueCode::ManifestRuntimeFailure, summary)
        .with_fingerprint("manifest_runtime_failure")
        .with_guidance(Guidance::fix_hint(
            "Manifest preflight/apply/validate failed. Could be a suite error OR a product bug. \
             Investigate whether the Go validator accepts what the CRD rejects.",
        ))
        .with_confidence(Confidence::High)
        .with_fix_safety(FixSafety::TriageRequired)
        .with_source_tool(context.source_tool);
        context.emit_current(issues, blueprint);
    } else if is_harness_authoring {
        let summary = format!("Harness authoring command failed (exit {exit_code})");
        let blueprint =
            IssueBlueprint::from_code(IssueCode::HarnessAuthoringCommandFailure, summary)
                .with_fingerprint("harness_authoring_failure")
                .with_guidance(Guidance::fix_hint(
                    "Harness authoring command returned non-zero - check payload or arguments",
                ))
                .with_confidence(Confidence::High)
                .with_fix_safety(FixSafety::AutoFixGuarded)
                .with_source_tool(context.source_tool);
        context.emit_current(issues, blueprint);
    } else if exit_code != 1 {
        let summary = format!("Non-zero exit code {exit_code}");
        let blueprint = IssueBlueprint::from_code(IssueCode::NonZeroExitCode, summary)
            .with_fingerprint("non_zero_exit_code")
            .with_guidance(Guidance::advisory(format!(
                "Command exited with code {exit_code}"
            )))
            .with_confidence(Confidence::Medium)
            .with_fix_safety(FixSafety::AdvisoryOnly)
            .with_source_tool(context.source_tool);
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
    let blueprint = IssueBlueprint::from_code(IssueCode::SubagentPermissionFailure, summary)
        .with_fingerprint(agent_name)
        .with_guidance(Guidance::fix_hint(
            "Subagent needs permissionMode dontAsk or mode auto for Bash/Write",
        ))
        .with_confidence(Confidence::High)
        .with_fix_safety(FixSafety::AutoFixSafe)
        .with_source_tool(context.source_tool);
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
    let blueprint = IssueBlueprint::from_code(IssueCode::SubagentManualRecovery, summary)
        .with_guidance(Guidance::fix_hint(
            "Subagent lacks write permissions or hit a harness CLI error during save",
        ))
        .with_confidence(Confidence::Medium)
        .with_fix_safety(FixSafety::AutoFixGuarded)
        .with_source_tool(context.source_tool);
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
        let blueprint = IssueBlueprint::from_code(
            IssueCode::ManualPayloadRecovery,
            "Manual payload recovery from subagent output",
        )
        .with_guidance(Guidance::fix_hint(
            "Subagent should save its own payload - manual grep recovery is a workflow failure",
        ))
        .with_confidence(Confidence::Low)
        .with_fix_safety(FixSafety::AdvisoryOnly)
        .with_source_tool(context.source_tool);
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
            let blueprint = IssueBlueprint::from_code(
                IssueCode::MissingClaudeSessionId,
                "CLAUDE_SESSION_ID is unset - harness cannot resolve session context",
            )
            .with_guidance(Guidance::fix_target_hint(
                "src/context.rs",
                "Session ID env var not set. Harness init and runner-state \
                 cannot find the context directory without it.",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AutoFixSafe)
            .with_source_tool(context.source_tool);
            context.emit_current(issues, blueprint);
        } else if signal.contains("kubeconfig") {
            let blueprint = IssueBlueprint::from_code(
                IssueCode::EmptyKubeconfig,
                "KUBECONFIG is empty - cluster commands will hit default context",
            )
            .with_guidance(Guidance::fix_target_hint(
                "skills/run/SKILL.md",
                "harness cluster should set KUBECONFIG to the k3d cluster config. \
                 Without it, kubectl defaults to ~/.kube/config which may point \
                 to a corporate cluster.",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AutoFixSafe)
            .with_source_tool(context.source_tool);
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
    let blueprint = IssueBlueprint::from_code(
        IssueCode::IncompleteWriterOutput,
        "Writer subagent produced incomplete output",
    )
    .with_guidance(Guidance::fix_hint(
        "Writer agent failed to save all files - check permissions and payload size",
    ))
    .with_confidence(Confidence::Medium)
    .with_fix_safety(FixSafety::AutoFixGuarded)
    .with_source_tool(context.source_tool);
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
        let confidence = if direct_match {
            Confidence::High
        } else {
            Confidence::Medium
        };
        let blueprint = IssueBlueprint::from_code(
            IssueCode::HarnessInfrastructureMisconfiguration,
            "Harness infrastructure misconfiguration detected",
        )
        .with_fingerprint("harness_infrastructure_misconfiguration")
        .with_guidance(Guidance::fix_hint(
            "Fix the harness bootstrap/cluster command to handle this automatically",
        ))
        .with_confidence(confidence)
        .with_fix_safety(FixSafety::TriageRequired)
        .with_source_tool(context.source_tool);
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
        let blueprint = IssueBlueprint::from_code(
            IssueCode::MissingConnectionOrEnvVar,
            "Missing configuration or connection acknowledged by assistant",
        )
        .with_fingerprint("missing_connection_or_env_var")
        .with_guidance(Guidance::advisory(
            "Could be a harness bootstrap gap or a product bug - investigate which layer dropped it",
        ))
        .with_confidence(Confidence::Medium)
        .with_fix_safety(FixSafety::AdvisoryOnly)
        .with_source_tool(context.source_tool);
        context.emit_current(issues, blueprint);
    }
}

/// Check for jq errors in Bash command output.
/// Caller guarantees: `source_tool` == Bash.
pub(super) fn check_jq_errors(context: &mut TextCheckContext<'_>, issues: &mut Vec<Issue>) {
    let has_jq_error = context.lower.contains("jq: error")
        || (context.lower.contains("parse error") && context.lower.contains("jq"));

    let has_null_iteration = context.lower.contains("cannot iterate over null")
        || context.lower.contains("null is not iterable");

    if has_jq_error || has_null_iteration {
        let blueprint = IssueBlueprint::from_code(
            IssueCode::JqErrorInCommandOutput,
            "jq parse/iteration error in command output",
        )
        .with_fingerprint("jq_error_in_output")
        .with_guidance(Guidance::advisory(
            "Check that the upstream command produces valid JSON before piping to jq. \
             Use harness diff or harness envoy for structured comparisons.",
        ))
        .with_confidence(Confidence::High)
        .with_fix_safety(FixSafety::AdvisoryOnly)
        .with_source_tool(context.source_tool);
        context.emit_current(issues, blueprint);
    }
}

/// Check for KSRCLI008 verdict-pending errors during closeout.
/// Caller guarantees: `source_tool` == Bash.
pub(super) fn check_closeout_verdict_pending(
    context: &mut TextCheckContext<'_>,
    issues: &mut Vec<Issue>,
) {
    if !context.lower.contains("ksrcli008") && !context.lower.contains("verdict is still pending") {
        return;
    }
    let blueprint = IssueBlueprint::from_code(
        IssueCode::CloseoutVerdictPending,
        "Closeout blocked - no final verdict set",
    )
    .with_fingerprint("closeout_verdict_pending")
    .with_guidance(Guidance::fix_hint(
        "harness closeout should auto-compute verdict from run-status.json counts",
    ))
    .with_confidence(Confidence::High)
    .with_fix_safety(FixSafety::AutoFixSafe)
    .with_source_tool(context.source_tool);
    context.emit_current(issues, blueprint);
}

/// Check for runner-state CLI event transition errors.
/// Caller guarantees: `source_tool` == Bash.
pub(super) fn check_runner_state_event_error(
    context: &mut TextCheckContext<'_>,
    issues: &mut Vec<Issue>,
) {
    let has_event_transition = context
        .lower
        .contains("event-based transitions are handled by the workflow module");
    let has_state_query_only = context
        .lower
        .contains("this cli path only supports state queries");
    if !has_event_transition && !has_state_query_only {
        return;
    }
    let blueprint = IssueBlueprint::from_code(
        IssueCode::RunnerStateEventNotSupported,
        "runner-state event transition not supported via CLI",
    )
    .with_fingerprint("runner_state_event_not_supported")
    .with_guidance(Guidance::fix_hint(
        "Use the workflow module's request functions or fix the CLI to support transitions",
    ))
    .with_confidence(Confidence::High)
    .with_fix_safety(FixSafety::AutoFixSafe)
    .with_source_tool(context.source_tool);
    context.emit_current(issues, blueprint);
}

/// Check for a stale runner state machine in Bash output.
///
/// When `suite-run-state.json` content shows `transition_count: 0` or
/// `phase: bootstrap` while group execution output has already appeared,
/// the state machine never advanced.
/// Caller guarantees: `source_tool` == Bash.
pub(super) fn check_runner_state_machine_stale(
    context: &mut TextCheckContext<'_>,
    issues: &mut Vec<Issue>,
) {
    // Only trigger when the output looks like suite-run-state.json content
    if !context.lower.contains("suite-run-state") && !context.lower.contains("transition_count") {
        return;
    }

    let has_zero_transitions = context.lower.contains("transition_count: 0")
        || context.lower.contains("\"transition_count\": 0")
        || context.lower.contains("\"transition_count\":0");
    let has_bootstrap_phase = context.lower.contains("\"phase\": \"bootstrap\"")
        || context.lower.contains("\"phase\":\"bootstrap\"")
        || context.lower.contains("phase: bootstrap");

    // Need at least one stale signal and evidence of group execution
    let has_group_evidence = context.lower.contains("group") || context.lower.contains("passed");

    if (has_zero_transitions || has_bootstrap_phase) && has_group_evidence {
        let blueprint = IssueBlueprint::from_code(
            IssueCode::RunnerStateMachineStale,
            "Runner state machine never advanced",
        )
        .with_fingerprint("runner_state_machine_stale")
        .with_guidance(Guidance::fix_hint(
            "State should advance automatically during harness commands",
        ))
        .with_confidence(Confidence::Medium)
        .with_fix_safety(FixSafety::AutoFixGuarded)
        .with_source_tool(context.source_tool);
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
        let blueprint = IssueBlueprint::from_code(
            IssueCode::UserFrustrationDetected,
            "User frustration signal detected",
        )
        .with_guidance(Guidance::advisory(
            "Review what happened before this - likely a UX issue",
        ))
        .with_confidence(Confidence::Low)
        .with_fix_safety(FixSafety::AdvisoryOnly)
        .with_source_tool(context.source_tool);
        context.emit_current(issues, blueprint);
    }
}
