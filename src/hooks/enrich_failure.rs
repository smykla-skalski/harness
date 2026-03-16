use crate::errors::{CliError, HookMessage};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::workflow::runner::{
    self as runner_wf, FailureKind, FailureState, PreflightStatus, RunnerPhase, RunnerWorkflowState,
};

/// Execute the enrich-failure hook.
///
/// For suite:run, emits run verdict info after a tool failure and
/// triggers triage transitions when appropriate.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active || !ctx.is_suite_runner() {
        return Ok(HookResult::allow());
    }
    let Some(run) = &ctx.run else {
        return Ok(HookResult::allow());
    };
    let Some(status) = &run.status else {
        return Ok(HookMessage::run_verdict("pending").into_result());
    };
    let Some(state) = &ctx.runner_state else {
        return Ok(HookMessage::run_verdict(status.overall_verdict.to_string()).into_result());
    };
    let words = ctx.command_words().unwrap_or_default();
    if words.len() >= 2 && words[0] == "harness" {
        let sub = words[1].as_str();
        if matches!(sub, "apply" | "validate") && state.phase == RunnerPhase::Execution {
            let new_state = request_failure_triage(state, FailureKind::Manifest);
            if let Some(ref rd) = ctx.effective_run_dir() {
                runner_wf::write_runner_state(rd, &new_state)?;
            }
        } else if state.phase == RunnerPhase::Preflight && matches!(sub, "preflight" | "capture") {
            let new_state = request_preflight_failed(state);
            if let Some(ref rd) = ctx.effective_run_dir() {
                runner_wf::write_runner_state(rd, &new_state)?;
            }
        }
    }
    Ok(HookMessage::run_verdict(status.overall_verdict.to_string()).into_result())
}

fn request_failure_triage(state: &RunnerWorkflowState, kind: FailureKind) -> RunnerWorkflowState {
    let mut new_state = state.clone();
    new_state.phase = RunnerPhase::Triage;
    new_state.failure = Some(FailureState {
        kind,
        suite_target: None,
        message: None,
    });
    new_state.transition_count += 1;
    new_state.last_event = Some("FailureTriageRequested".to_string());
    new_state.updated_at = chrono::Utc::now().to_rfc3339();
    new_state
}

fn request_preflight_failed(state: &RunnerWorkflowState) -> RunnerWorkflowState {
    let mut new_state = state.clone();
    new_state.preflight.status = PreflightStatus::Pending;
    new_state.transition_count += 1;
    new_state.last_event = Some("PreflightFailed".to_string());
    new_state.updated_at = chrono::Utc::now().to_rfc3339();
    new_state
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workflow::runner::PreflightState;

    fn base_state() -> RunnerWorkflowState {
        RunnerWorkflowState {
            schema_version: 1,
            phase: RunnerPhase::Execution,
            preflight: PreflightState {
                status: PreflightStatus::Complete,
            },
            failure: None,
            suite_fix: None,
            updated_at: String::new(),
            transition_count: 0,
            last_event: None,
        }
    }

    #[test]
    fn request_failure_triage_sets_phase_and_failure() {
        let state = base_state();
        let result = request_failure_triage(&state, FailureKind::Manifest);
        assert_eq!(result.phase, RunnerPhase::Triage);
        assert!(result.failure.is_some());
        assert_eq!(result.failure.unwrap().kind, FailureKind::Manifest);
        assert_eq!(result.transition_count, 1);
        assert_eq!(result.last_event.as_deref(), Some("FailureTriageRequested"));
    }

    #[test]
    fn request_preflight_failed_resets_status() {
        let mut state = base_state();
        state.phase = RunnerPhase::Preflight;
        state.preflight.status = PreflightStatus::Running;
        let result = request_preflight_failed(&state);
        assert_eq!(result.preflight.status, PreflightStatus::Pending);
        assert_eq!(result.transition_count, 1);
        assert_eq!(result.last_event.as_deref(), Some("PreflightFailed"));
    }
}
