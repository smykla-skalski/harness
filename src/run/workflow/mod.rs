mod persistence;
mod transitions;
mod types;

use std::fmt;
use std::path::Path;

use crate::errors::{CliError, CliErrorKind};
use crate::run::audit::append_runner_state_audit;

pub use persistence::{
    initialize_runner_state, read_runner_state, runner_state_path, write_runner_state,
    write_runner_state_if_current,
};
pub use types::{
    FailureKind, FailureState, ManifestFixDecision, PreflightState, PreflightStatus, RunnerEvent,
    RunnerNextAction, RunnerPhase, RunnerWorkflowState, SuiteFixState, TransitionRecord,
};

use persistence::{make_initial_state, update_runner_state};
use transitions::{
    apply_failure_manifest, apply_preflight_status, apply_suite_fix,
    clear_triage_state_on_forward_movement, resolve_transition,
};

fn now_utc() -> String {
    chrono::Utc::now().to_rfc3339()
}

/// Apply a named event to the runner state, advancing the phase when valid.
///
/// Returns the updated state after persisting to disk. Invalid transitions
/// produce `CliErrorKind::InvalidTransition`.
///
/// # Errors
/// Returns `CliError` on invalid transition or IO failure.
pub fn apply_event<E>(
    run_dir: &Path,
    event: E,
    suite_target: Option<&str>,
    message: Option<&str>,
) -> Result<RunnerWorkflowState, CliError>
where
    E: TryInto<RunnerEvent>,
    E::Error: fmt::Display,
{
    let event = event
        .try_into()
        .map_err(|error| CliErrorKind::invalid_transition(format!("unknown event: {error}")))?;
    let updated = update_runner_state(run_dir, |current| {
        let mut state = current.unwrap_or_else(|| make_initial_state(&now_utc()));

        let new_phase = resolve_transition(&mut state, event)?;
        state.phase = new_phase;

        clear_triage_state_on_forward_movement(&mut state, new_phase);
        apply_preflight_status(&mut state, event);
        apply_failure_manifest(&mut state, event, suite_target, message);
        apply_suite_fix(&mut state, event, new_phase, suite_target);

        Ok(Some(state))
    })?;
    let Some(state) = updated else {
        unreachable!("runner updates always persist a state");
    };
    append_runner_state_audit(run_dir, &state)?;
    Ok(state)
}

/// Advance the runner phase to the execution phase if it is still in
/// bootstrap or preflight. Called automatically when commands like
/// `report group` or `apply` indicate the run is actively executing.
///
/// Returns `true` if the phase was advanced, `false` if already past those
/// early phases.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn ensure_execution_phase(run_dir: &Path) -> Result<bool, CliError> {
    let updated = update_runner_state(run_dir, |current| {
        let Some(mut state) = current else {
            return Ok(None);
        };
        if matches!(state.phase, RunnerPhase::Bootstrap | RunnerPhase::Preflight) {
            state.phase = RunnerPhase::Execution;
            state.touch("AutoAdvanceToExecution");
            return Ok(Some(state));
        }
        Ok(None)
    })?;
    if let Some(state) = updated.as_ref() {
        append_runner_state_audit(run_dir, state)?;
    }
    Ok(updated.is_some())
}

/// Get the next action hint based on runner state.
#[must_use]
pub fn next_action(state: Option<&RunnerWorkflowState>) -> RunnerNextAction {
    let Some(state) = state else {
        return RunnerNextAction::ReloadState;
    };
    match state.phase {
        RunnerPhase::Bootstrap => RunnerNextAction::FinishBootstrap,
        RunnerPhase::Preflight => {
            if state.preflight.status == PreflightStatus::Running {
                RunnerNextAction::FinishPreflightWorker
            } else {
                RunnerNextAction::ExecutePreflight
            }
        }
        RunnerPhase::Execution => RunnerNextAction::ContinueExecution,
        RunnerPhase::Triage => {
            if state.suite_fix.is_some() {
                RunnerNextAction::FinishSuiteRepair
            } else {
                RunnerNextAction::ResolveTriage
            }
        }
        RunnerPhase::Closeout => RunnerNextAction::FinishCloseout,
        RunnerPhase::Completed => RunnerNextAction::ReviewReport,
        RunnerPhase::Suspended => RunnerNextAction::ResumeRun,
        RunnerPhase::Aborted => RunnerNextAction::HandleAbort,
    }
}

#[cfg(test)]
mod tests;
