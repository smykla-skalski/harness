use std::path::{Path, PathBuf};

use crate::audit_log::append_runner_state_audit;
use crate::errors::{CliError, CliErrorKind, cow};
use crate::rules::skill_dirs;
use crate::workflow::engine::VersionedJsonRepository;

use super::types::{
    PreflightState, PreflightStatus, RunnerPhase, RunnerWorkflowState,
};

pub(super) const RUNNER_STATE_SCHEMA_VERSION: u32 = 2;

/// Path to the runner state file.
#[must_use]
pub fn runner_state_path(run_dir: &Path) -> PathBuf {
    run_dir.join(skill_dirs::RUN_STATE_FILE)
}

pub(super) fn runner_repository(
    run_dir: &Path,
) -> VersionedJsonRepository<RunnerWorkflowState> {
    VersionedJsonRepository::new(runner_state_path(run_dir), RUNNER_STATE_SCHEMA_VERSION)
}

pub(super) fn make_initial_state(occurred_at: &str) -> RunnerWorkflowState {
    RunnerWorkflowState {
        schema_version: RUNNER_STATE_SCHEMA_VERSION,
        phase: RunnerPhase::Bootstrap,
        preflight: PreflightState {
            status: PreflightStatus::Pending,
        },
        failure: None,
        suite_fix: None,
        updated_at: occurred_at.to_string(),
        transition_count: 0,
        last_event: Some("RunInitialized".to_string()),
    }
}

pub(super) fn save_state(
    run_dir: &Path,
    state: &RunnerWorkflowState,
) -> Result<(), CliError> {
    let repo = runner_repository(run_dir);
    repo.save(state)?;
    append_runner_state_audit(run_dir, state)?;
    Ok(())
}

/// Initialize runner state for a new run.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn initialize_runner_state(
    run_dir: &Path,
) -> Result<RunnerWorkflowState, CliError> {
    let state = make_initial_state(&super::now_utc());
    save_state(run_dir, &state)?;
    Ok(state)
}

/// Read runner state from disk.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn read_runner_state(
    run_dir: &Path,
) -> Result<Option<RunnerWorkflowState>, CliError> {
    let repo = runner_repository(run_dir);
    let loaded = match repo.load() {
        Ok(loaded) => loaded,
        Err(error) if error.code() == "WORKFLOW_VERSION" => {
            return Err(CliErrorKind::workflow_version(cow!(
                "runner state requires schema version 2"
            ))
            .with_details(format!(
                "Delete {} or re-run `harness init` to regenerate the runner state.",
                runner_state_path(run_dir).display()
            )));
        }
        Err(error) => return Err(error),
    };
    match loaded {
        Some(state) => Ok(Some(state)),
        None => Ok(None),
    }
}

/// Write runner state to disk.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn write_runner_state(
    run_dir: &Path,
    state: &RunnerWorkflowState,
) -> Result<(), CliError> {
    save_state(run_dir, state)
}
