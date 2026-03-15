use crate::errors::{self, CliError};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::workflow::runner::{
    self as runner_wf, FailureKind, FailureState, PreflightStatus, RunnerEvent, RunnerPhase,
    RunnerWorkflowState,
};

/// Execute the enrich-failure hook.
///
/// For suite-runner, emits run verdict info after a tool failure and
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
        return Ok(errors::hook_msg(
            &errors::INFO_RUN_VERDICT,
            &[("verdict", "pending")],
        ));
    };
    let Some(state) = &ctx.runner_state else {
        return Ok(errors::hook_msg(
            &errors::INFO_RUN_VERDICT,
            &[("verdict", &status.overall_verdict)],
        ));
    };
    let words = ctx.command_words();
    if words.len() >= 2 && words[0] == "harness" {
        let sub = words[1].as_str();
        if matches!(sub, "apply" | "validate") && state.phase == RunnerPhase::Execution {
            let new_state = request_failure_triage(state, FailureKind::Manifest);
            if let Some(ref rd) = ctx.effective_run_dir() {
                let _ = runner_wf::write_runner_state(rd, &new_state);
            }
        } else if matches!(&state.phase, RunnerPhase::Preflight { .. })
            && matches!(sub, "preflight" | "capture")
        {
            let new_state = request_preflight_failed(state);
            if let Some(ref rd) = ctx.effective_run_dir() {
                let _ = runner_wf::write_runner_state(rd, &new_state);
            }
        }
    }
    Ok(errors::hook_msg(
        &errors::INFO_RUN_VERDICT,
        &[("verdict", &status.overall_verdict)],
    ))
}

fn request_failure_triage(state: &RunnerWorkflowState, kind: FailureKind) -> RunnerWorkflowState {
    state
        .transition(
            RunnerEvent::FailureTriageRequested,
            RunnerPhase::Triage {
                failure: FailureState {
                    kind,
                    suite_target: None,
                    message: None,
                },
                suite_fix: None,
            },
        )
        .unwrap_or_else(|_| state.clone())
}

fn request_preflight_failed(state: &RunnerWorkflowState) -> RunnerWorkflowState {
    state
        .transition(
            RunnerEvent::PreflightFailed,
            RunnerPhase::Preflight {
                status: PreflightStatus::Pending,
            },
        )
        .unwrap_or_else(|_| state.clone())
}
