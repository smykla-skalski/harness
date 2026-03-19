use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_text, write_json_pretty};
use crate::rules::skill_dirs;
use crate::run::audit::append_runner_state_audit;
use fs_err as fs;
use fs2::FileExt;
use std::fs::{File, OpenOptions};

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

fn open_runner_lock_file(run_dir: &Path) -> Result<File, CliError> {
    let lock_path = runner_lock_path(run_dir);
    if let Some(parent) = lock_path.parent() {
        fs::create_dir_all(parent).map_err(|error| -> CliError {
            CliErrorKind::workflow_io(format!(
                "failed to create runner lock directory {}: {error}",
                parent.display()
            ))
            .into()
        })?;
    }

    OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(&lock_path)
        .map_err(|error| -> CliError {
            CliErrorKind::workflow_io(format!(
                "failed to open runner lock {}: {error}",
                lock_path.display()
            ))
            .into()
        })
}

fn with_runner_lock<R>(
    run_dir: &Path,
    action: impl FnOnce() -> Result<R, CliError>,
) -> Result<R, CliError> {
    let lock_file = open_runner_lock_file(run_dir)?;
    lock_file.lock_exclusive().map_err(|error| -> CliError {
        CliErrorKind::workflow_io(format!(
            "failed to acquire runner lock {}: {error}",
            runner_lock_path(run_dir).display()
        ))
        .into()
    })?;

    let result = action();
    let unlock_result = lock_file.unlock().map_err(|error| -> CliError {
        CliErrorKind::workflow_io(format!(
            "failed to release runner lock {}: {error}",
            runner_lock_path(run_dir).display()
        ))
        .into()
    });

    match (result, unlock_result) {
        (Ok(value), Ok(())) => Ok(value),
        (Err(error), Ok(()) | Err(_)) | (Ok(_), Err(error)) => Err(error),
    }
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
mod tests {
    use std::fs;

    use serde_json::json;
    use tempfile::TempDir;

    use super::*;
    use crate::run::workflow::{ManifestFixDecision, SuiteFixState};

    #[test]
    fn read_runner_state_rejects_legacy_flat_state() {
        let dir = TempDir::new().unwrap();
        let path = runner_state_path(dir.path());
        let v1 = json!({
            "phase": "triage",
            "preflight": { "status": "complete" },
            "failure": null,
            "suite_fix": {
                "approved_paths": ["groups/demo.md"],
                "suite_written": true,
                "amendments_written": false,
                "decision": "Fix in suite and this run"
            },
            "updated_at": "2025-01-01T00:00:00Z",
            "transition_count": 4,
            "last_event": "ManifestFixAnswered"
        });
        fs::write(&path, serde_json::to_string_pretty(&v1).unwrap()).unwrap();

        let error = read_runner_state(dir.path()).unwrap_err();
        assert_eq!(error.code(), "WORKFLOW_PARSE");
        assert!(
            error
                .details()
                .unwrap_or_default()
                .contains("harness run init")
        );
    }

    #[test]
    fn read_runner_state_ignores_legacy_file_name() {
        let dir = TempDir::new().unwrap();
        let legacy_path = dir.path().join("runner-state.json");
        let v1 = json!({
            "state": {
                "phase": "bootstrap",
                "preflight": { "status": "pending" }
            },
            "updated_at": "2025-01-01T00:00:00Z",
            "transition_count": 0,
            "last_event": "RunInitialized"
        });
        fs::write(&legacy_path, serde_json::to_string_pretty(&v1).unwrap()).unwrap();

        let state = read_runner_state(dir.path()).unwrap();
        assert!(state.is_none());
        assert!(!runner_state_path(dir.path()).exists());
    }

    #[test]
    fn write_runner_state_persists_strict_shape() {
        let dir = TempDir::new().unwrap();
        let mut state = make_initial_state("2025-01-01T00:00:00Z");
        state.phase = RunnerPhase::Execution;
        state.transition_count = 3;
        write_runner_state(dir.path(), &state).unwrap();

        let json: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(runner_state_path(dir.path())).unwrap())
                .unwrap();
        assert!(json.get("schema_version").is_none());
        assert_eq!(json["state"]["phase"], "execution");
    }

    #[test]
    fn write_runner_state_if_current_rejects_conflict() {
        let dir = TempDir::new().unwrap();
        let mut state = make_initial_state("2025-01-01T00:00:00Z");
        state.phase = RunnerPhase::Triage;
        state.transition_count = 3;
        state.suite_fix = Some(SuiteFixState {
            approved_paths: vec![],
            suite_written: false,
            amendments_written: false,
            decision: ManifestFixDecision::SuiteAndRun,
        });
        write_runner_state(dir.path(), &state).unwrap();

        let mut next = state;
        next.transition_count = 4;
        next.suite_fix = Some(SuiteFixState {
            approved_paths: vec![],
            suite_written: true,
            amendments_written: false,
            decision: ManifestFixDecision::SuiteAndRun,
        });

        let error = write_runner_state_if_current(dir.path(), 2, &next).unwrap_err();
        assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    }
}
