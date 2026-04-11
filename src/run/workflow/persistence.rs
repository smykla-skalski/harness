use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_text, write_json_pretty};
use crate::infra::persistence::flock::{FlockErrorContext, with_exclusive_flock};
use crate::kernel::skills::dirs as skill_dirs;
use crate::run::audit::append_runner_state_audit;

use super::types::{PreflightState, PreflightStatus, RunnerPhase, RunnerWorkflowState};

/// Path to the runner state file.
#[must_use]
pub fn runner_state_path(run_dir: &Path) -> PathBuf {
    run_dir.join(skill_dirs::RUN_STATE_FILE)
}

#[must_use]
fn runner_lock_path(run_dir: &Path) -> PathBuf {
    let path = runner_state_path(run_dir);
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(skill_dirs::RUN_STATE_FILE);
    path.with_file_name(format!("{file_name}.lock"))
}

fn with_runner_lock<R>(
    run_dir: &Path,
    action: impl FnOnce() -> Result<R, CliError>,
) -> Result<R, CliError> {
    with_exclusive_flock(
        &runner_lock_path(run_dir),
        FlockErrorContext::new("runner persistence"),
        action,
    )
}

fn load_runner_state_file(path: &Path) -> Result<Option<RunnerWorkflowState>, CliError> {
    if !path.exists() {
        return Ok(None);
    }

    let text = read_text(path)?;
    let state = serde_json::from_str(&text).map_err(|error| {
        CliErrorKind::workflow_parse(format!(
            "failed to parse runner workflow: {}",
            path.display()
        ))
        .with_details(format!(
            "{error}\nDelete {} or re-run `harness run init` to regenerate the runner state.",
            path.display()
        ))
    })?;
    Ok(Some(state))
}

fn save_runner_state_file(path: &Path, state: &RunnerWorkflowState) -> Result<(), CliError> {
    write_json_pretty(path, state)
}

pub(super) fn update_runner_state<F>(
    run_dir: &Path,
    update: F,
) -> Result<Option<RunnerWorkflowState>, CliError>
where
    F: FnOnce(Option<RunnerWorkflowState>) -> Result<Option<RunnerWorkflowState>, CliError>,
{
    with_runner_lock(run_dir, || {
        let path = runner_state_path(run_dir);
        let current = load_runner_state_file(&path)?;
        let next = update(current)?;

        if let Some(state) = next.as_ref() {
            save_runner_state_file(&path, state)?;
        }

        Ok(next)
    })
}

pub(super) fn make_initial_state(occurred_at: &str) -> RunnerWorkflowState {
    RunnerWorkflowState {
        phase: RunnerPhase::Bootstrap,
        preflight: PreflightState {
            status: PreflightStatus::Pending,
        },
        failure: None,
        suite_fix: None,
        updated_at: occurred_at.to_string(),
        transition_count: 0,
        last_event: Some("RunInitialized".to_string()),
        history: Vec::new(),
    }
}

pub(super) fn save_state(run_dir: &Path, state: &RunnerWorkflowState) -> Result<(), CliError> {
    with_runner_lock(run_dir, || {
        save_runner_state_file(&runner_state_path(run_dir), state)
    })?;
    append_runner_state_audit(run_dir, state)?;
    Ok(())
}

/// Initialize runner state for a new run.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn initialize_runner_state(run_dir: &Path) -> Result<RunnerWorkflowState, CliError> {
    let state = make_initial_state(&super::now_utc());
    save_state(run_dir, &state)?;
    Ok(state)
}

/// Read runner state from disk.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn read_runner_state(run_dir: &Path) -> Result<Option<RunnerWorkflowState>, CliError> {
    with_runner_lock(run_dir, || {
        load_runner_state_file(&runner_state_path(run_dir))
    })
}

/// Write runner state to disk.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn write_runner_state(run_dir: &Path, state: &RunnerWorkflowState) -> Result<(), CliError> {
    save_state(run_dir, state)
}

/// Write runner state only if the currently persisted transition count still matches.
///
/// # Errors
/// Returns `CliError` on IO failure or concurrent modification.
pub fn write_runner_state_if_current(
    run_dir: &Path,
    expected_transition_count: u32,
    state: &RunnerWorkflowState,
) -> Result<bool, CliError> {
    let current_path = runner_state_path(run_dir);

    let desired = state.clone();
    let updated = update_runner_state(run_dir, |current| {
        let Some(current) = current else {
            return Err(CliErrorKind::concurrent_modification(format!(
                "missing runner state while applying {}",
                desired.last_event.as_deref().unwrap_or("runner transition")
            ))
            .with_details(format!(
                "Re-run `harness run init` or reload {} before retrying.",
                current_path.display()
            )));
        };
        if current.transition_count != expected_transition_count {
            return Err(CliErrorKind::concurrent_modification(format!(
                "expected runner transition_count {expected_transition_count}, found {}",
                current.transition_count
            ))
            .with_details(format!(
                "Reload {} before retrying the runner state transition.",
                current_path.display()
            )));
        }
        Ok(Some(desired.clone()))
    })?;

    if updated.is_some() {
        append_runner_state_audit(run_dir, state)?;
    }
    Ok(updated.is_some())
}

#[cfg(test)]
#[path = "persistence/tests.rs"]
mod tests;
