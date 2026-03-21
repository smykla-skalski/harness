use crate::errors::{CliError, HookMessage};
use crate::hooks::application::GuardContext as HookContext;
use crate::kernel::command_intent::HarnessCommandInvocationRef;
use crate::run::workflow::{FailureKind, RunnerPhase, RunnerWorkflowState};

use super::effects::{self, HookOutcome};

/// Execute the enrich-failure hook.
///
/// For suite:run, emits run verdict info after a tool failure and
/// triggers triage transitions when appropriate.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookOutcome, CliError> {
    if !ctx.skill_active || !ctx.is_suite_runner() {
        return Ok(HookOutcome::allow());
    }
    let Some(run) = &ctx.run else {
        return Ok(HookOutcome::allow());
    };
    let Some(status) = &run.status else {
        return Ok(HookOutcome::from_hook_result(
            HookMessage::run_verdict("pending").into_result(),
        ));
    };
    let Some(state) = &ctx.runner_state else {
        return Ok(HookOutcome::from_hook_result(
            HookMessage::run_verdict(status.overall_verdict.to_string()).into_result(),
        ));
    };
    let mut outcome = HookOutcome::from_hook_result(
        HookMessage::run_verdict(status.overall_verdict.to_string()).into_result(),
    );
    let subcommand = ctx.parsed_command()?.and_then(|command| {
        command
            .first_harness_invocation()
            .and_then(HarnessCommandInvocationRef::subcommand)
    });
    if let Some(sub) = subcommand {
        if matches!(sub, "apply" | "validate") && state.phase() == RunnerPhase::Execution {
            if let Some(effect) = effects::transition_runner_state(ctx, |state| {
                Some(request_failure_triage(state, FailureKind::Manifest))
            }) {
                outcome = outcome.with_effect(effect);
            }
        } else if state.phase() == RunnerPhase::Preflight
            && matches!(sub, "preflight" | "capture")
            && let Some(effect) =
                effects::transition_runner_state(ctx, |state| Some(request_preflight_failed(state)))
        {
            outcome = outcome.with_effect(effect);
        }
    }
    Ok(outcome)
}

fn request_failure_triage(state: &RunnerWorkflowState, kind: FailureKind) -> RunnerWorkflowState {
    state.request_failure_triage(kind, None, None, "FailureTriageRequested")
}

fn request_preflight_failed(state: &RunnerWorkflowState) -> RunnerWorkflowState {
    state.request_preflight_failed("PreflightFailed")
}

#[cfg(test)]
#[path = "enrich_failure/tests.rs"]
mod tests;
