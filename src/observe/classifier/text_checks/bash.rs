use super::super::emitter::{Guidance, IssueBlueprint};
use super::super::{EXIT_CODE_REGEX, TextCheckContext};
use crate::observe::patterns;
use crate::observe::types::{Confidence, FixSafety, Issue, IssueCategory, IssueCode};

/// Check for KSA hook codes in Bash output.
/// Caller guarantees: `source_tool` == Bash.
pub(crate) fn check_ksa_codes(context: &mut TextCheckContext<'_>, issues: &mut Vec<Issue>) {
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
pub(crate) fn check_exit_code_issues(context: &mut TextCheckContext<'_>, issues: &mut Vec<Issue>) {
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

    let is_harness_create = context.lower.contains("harness") && context.lower.contains("create");

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
    } else if is_harness_create {
        let summary = format!("Harness create command failed (exit {exit_code})");
        let blueprint = IssueBlueprint::from_code(IssueCode::HarnessCreateCommandFailure, summary)
            .with_fingerprint("harness_create_failure")
            .with_guidance(Guidance::fix_hint(
                "Harness create command returned non-zero - check payload or arguments",
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

/// Check for jq errors in Bash command output.
/// Caller guarantees: `source_tool` == Bash.
pub(crate) fn check_jq_errors(context: &mut TextCheckContext<'_>, issues: &mut Vec<Issue>) {
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
pub(crate) fn check_closeout_verdict_pending(
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
pub(crate) fn check_runner_state_event_error(
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
pub(crate) fn check_runner_state_machine_stale(
    context: &mut TextCheckContext<'_>,
    issues: &mut Vec<Issue>,
) {
    if !context.lower.contains("suite-run-state") && !context.lower.contains("transition_count") {
        return;
    }

    let has_zero_transitions = context.lower.contains("transition_count: 0")
        || context.lower.contains("\"transition_count\": 0")
        || context.lower.contains("\"transition_count\":0");
    let has_bootstrap_phase = context.lower.contains("\"phase\": \"bootstrap\"")
        || context.lower.contains("\"phase\":\"bootstrap\"")
        || context.lower.contains("phase: bootstrap");

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
