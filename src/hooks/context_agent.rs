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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workflow::runner::PreflightState;

    fn base_state(phase: RunnerPhase, preflight_status: PreflightStatus) -> RunnerWorkflowState {
        RunnerWorkflowState {
            schema_version: 1,
            phase,
            preflight: PreflightState {
                status: preflight_status,
            },
            failure: None,
            suite_fix: None,
            updated_at: String::new(),
            transition_count: 0,
            last_event: None,
        }
    }

    #[test]
    fn preflight_pending_allows_start() {
        let state = base_state(RunnerPhase::Preflight, PreflightStatus::Pending);
        let (allowed, reason) = can_start_preflight_worker(&state);
        assert!(allowed);
        assert!(reason.is_none());
    }

    #[test]
    fn preflight_running_allows_start() {
        let state = base_state(RunnerPhase::Preflight, PreflightStatus::Running);
        let (allowed, reason) = can_start_preflight_worker(&state);
        assert!(allowed);
        assert!(reason.is_none());
    }

    #[test]
    fn bootstrap_phase_denies_start() {
        let state = base_state(RunnerPhase::Bootstrap, PreflightStatus::Pending);
        let (allowed, reason) = can_start_preflight_worker(&state);
        assert!(!allowed);
        assert!(reason.is_some());
    }

    #[test]
    fn preflight_complete_denies_start() {
        let state = base_state(RunnerPhase::Preflight, PreflightStatus::Complete);
        let (allowed, reason) = can_start_preflight_worker(&state);
        assert!(!allowed);
        assert!(reason.unwrap().contains("already complete"));
    }
}
