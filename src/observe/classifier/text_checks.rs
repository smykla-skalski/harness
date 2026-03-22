mod bash;

pub(crate) use self::bash::{
    check_closeout_verdict_pending, check_exit_code_issues, check_jq_errors, check_ksa_codes,
    check_runner_state_event_error, check_runner_state_machine_stale,
};

use super::emitter::{Guidance, IssueBlueprint};
use super::{AGENT_NAME_REGEX, TextCheckContext};
use crate::observe::patterns;
use crate::observe::types::{Confidence, FixSafety, Issue, IssueCode};

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
                "harness setup kuma cluster should set KUBECONFIG to the harness-managed cluster \
                 kubeconfig. Without it, kubectl defaults to ~/.kube/config which may point to an \
                 unrelated cluster.",
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

/// Check for user frustration signals in human text.
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
