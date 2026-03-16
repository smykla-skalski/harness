use crate::errors::{CliError, CliErrorKind};

use super::types::{
    FailureKind, FailureState, PreflightStatus, RunnerEvent, RunnerPhase,
    RunnerWorkflowState, SuiteFixState,
};

/// Map an event name to the target phase, validating that the transition
/// is legal from the current phase.
pub(super) fn resolve_transition(
    state: &RunnerWorkflowState,
    event: RunnerEvent,
) -> Result<RunnerPhase, CliError> {
    let current = state.phase;
    let target = event.target_phase();

    // Validate the transition is legal.
    if !is_valid_transition(current, target, event) {
        return Err(CliErrorKind::invalid_transition(format!(
            "cannot apply '{}' in phase {current} (target: {target})",
            event.as_str()
        ))
        .into());
    }

    Ok(target)
}

/// Check whether a phase transition is allowed.
pub(super) fn is_valid_transition<E>(from: RunnerPhase, to: RunnerPhase, event: E) -> bool
where
    E: TryInto<RunnerEvent>,
{
    let Ok(event) = event.try_into() else {
        return false;
    };
    if let Some(allowed) = is_special_transition(from, to, event) {
        return allowed;
    }
    is_standard_transition(from, to)
}

/// Handle abort, suspend, and resume - these bypass normal phase rules.
/// Returns `Some(true/false)` when the event is special, `None` to fall through.
fn is_special_transition(
    from: RunnerPhase,
    to: RunnerPhase,
    event: RunnerEvent,
) -> Option<bool> {
    if matches!(to, RunnerPhase::Aborted | RunnerPhase::Suspended) {
        return Some(!matches!(from, RunnerPhase::Completed));
    }
    if event == RunnerEvent::ResumeRun {
        return Some(matches!(
            from,
            RunnerPhase::Suspended | RunnerPhase::Aborted
        ));
    }
    None
}

/// Check whether a standard (non-special) phase transition is allowed.
fn is_standard_transition(from: RunnerPhase, to: RunnerPhase) -> bool {
    match from {
        RunnerPhase::Bootstrap => matches!(
            to,
            RunnerPhase::Preflight | RunnerPhase::Execution | RunnerPhase::Triage
        ),
        RunnerPhase::Preflight => matches!(
            to,
            RunnerPhase::Execution | RunnerPhase::Triage | RunnerPhase::Preflight
        ),
        RunnerPhase::Execution => matches!(
            to,
            RunnerPhase::Triage | RunnerPhase::Closeout | RunnerPhase::Execution
        ),
        RunnerPhase::Triage => matches!(to, RunnerPhase::Execution | RunnerPhase::Triage),
        RunnerPhase::Closeout => matches!(to, RunnerPhase::Completed),
        RunnerPhase::Completed | RunnerPhase::Aborted | RunnerPhase::Suspended => false,
    }
}

/// Clear failure and `suite_fix` state when moving forward out of triage.
pub(super) fn clear_triage_state_on_forward_movement(
    state: &mut RunnerWorkflowState,
    new_phase: RunnerPhase,
) {
    if new_phase == RunnerPhase::Triage {
        return;
    }
    if state.failure.is_some() && !matches!(new_phase, RunnerPhase::Aborted) {
        state.failure = None;
    }
    if state.suite_fix.is_some() {
        state.suite_fix = None;
    }
}

/// Update preflight sub-state for preflight events.
pub(super) fn apply_preflight_status(
    state: &mut RunnerWorkflowState,
    event: RunnerEvent,
) {
    match event {
        RunnerEvent::PreflightStarted => state.preflight.status = PreflightStatus::Running,
        RunnerEvent::PreflightCaptured => state.preflight.status = PreflightStatus::Complete,
        _ => {}
    }
}

/// Set failure state on failure-manifest events.
pub(super) fn apply_failure_manifest(
    state: &mut RunnerWorkflowState,
    event: RunnerEvent,
    suite_target: Option<&str>,
    message: Option<&str>,
) {
    if event == RunnerEvent::FailureManifest {
        state.failure = Some(FailureState {
            kind: FailureKind::Manifest,
            suite_target: suite_target.map(str::to_string),
            message: message.map(str::to_string),
        });
    }
}

/// Set `suite_fix` on manifest-fix decisions that enter triage.
pub(super) fn apply_suite_fix(
    state: &mut RunnerWorkflowState,
    event: RunnerEvent,
    new_phase: RunnerPhase,
    suite_target: Option<&str>,
) {
    if let Some(decision) = event.manifest_fix_decision()
        && new_phase == RunnerPhase::Triage
    {
        state.suite_fix = Some(SuiteFixState {
            approved_paths: suite_target.map_or_else(Vec::new, |s| vec![s.to_string()]),
            suite_written: false,
            amendments_written: false,
            decision,
        });
    }
}

/// Produce a human-readable label for a workflow event.
#[cfg(test)]
pub(super) fn event_label(event: &str) -> String {
    RunnerEvent::try_from(event).map_or_else(
        |_| {
            event
                .split('-')
                .map(|segment| {
                    let mut characters = segment.chars();
                    match characters.next() {
                        None => String::new(),
                        Some(first) => {
                            let mut result = first.to_uppercase().to_string();
                            result.push_str(characters.as_str());
                            result
                        }
                    }
                })
                .collect::<String>()
        },
        |parsed| parsed.label().to_string(),
    )
}
