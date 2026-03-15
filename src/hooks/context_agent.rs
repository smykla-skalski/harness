use crate::errors::{CliError, HookMessage};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::workflow::runner::{PreflightStatus, RunnerPhase, RunnerWorkflowState};

/// Execute the context-agent hook.
///
/// For suite:new, emits a format warning reminding workers to save
/// structured results through `harness authoring-save`.
/// For suite:run, validates that the preflight worker can start by
/// checking runner workflow state.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    if ctx.is_suite_author() {
        return Ok(HookMessage::CodeReaderFormat.into_result());
    }
    // suite:run: validate preflight worker can start.
    let Some(state) = &ctx.runner_state else {
        return Ok(HookMessage::runner_state_invalid(
            "runner state is missing; initialize the suite run first",
        )
        .into_result());
    };
    let (allowed, reason) = can_start_preflight_worker(state);
    if !allowed {
        return Ok(HookMessage::runner_flow_required(
            "start the preflight worker",
            reason.unwrap_or("enter the guarded preflight phase before spawning the worker"),
        )
        .into_result());
    }
    Ok(HookResult::allow())
}

fn can_start_preflight_worker(state: &RunnerWorkflowState) -> (bool, Option<&'static str>) {
    if state.phase != RunnerPhase::Preflight {
        return (
            false,
            Some("enter the guarded preflight phase before spawning the worker"),
        );
    }
    if state.preflight.status != PreflightStatus::Pending
        && state.preflight.status != PreflightStatus::Running
    {
        return (
            false,
            Some("preflight is already complete; do not restart the worker"),
        );
    }
    (true, None)
}
