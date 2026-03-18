use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::Value;

use crate::audit_log::append_runner_state_audit;
use crate::errors::{CliError, CliErrorKind, cow};
use crate::rules::skill_dirs;
use crate::workflow::engine::VersionedJsonRepository;

use super::types::{
    FailureState, PreflightState, PreflightStatus, RunnerPhase, RunnerWorkflowPayload,
    RunnerWorkflowState, RunnerWorkflowStateRecord, SuiteFixState,
};

pub(super) const RUNNER_STATE_SCHEMA_VERSION: u32 = 2;
const LEGACY_RUNNER_STATE_FILE: &str = "suite-runner-state.json";

/// Path to the runner state file.
#[must_use]
pub fn runner_state_path(run_dir: &Path) -> PathBuf {
    run_dir.join(skill_dirs::RUN_STATE_FILE)
}

#[must_use]
fn legacy_runner_state_path(run_dir: &Path) -> PathBuf {
    run_dir.join(LEGACY_RUNNER_STATE_FILE)
}

pub(super) fn runner_repository(run_dir: &Path) -> VersionedJsonRepository<RunnerWorkflowState> {
    runner_repository_for_path(runner_state_path(run_dir))
}

fn runner_repository_for_path(path: PathBuf) -> VersionedJsonRepository<RunnerWorkflowState> {
    VersionedJsonRepository::new(path, RUNNER_STATE_SCHEMA_VERSION)
        .with_migrations(vec![Box::new(migrate_runner_v1_to_v2)])
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

pub(super) fn save_state(run_dir: &Path, state: &RunnerWorkflowState) -> Result<(), CliError> {
    let repo = runner_repository(run_dir);
    repo.save(state)?;
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
    let path = runner_state_path(run_dir);
    if path.exists() {
        return load_runner_state_repo(runner_repository_for_path(path.clone()), &path);
    }

    let legacy_path = legacy_runner_state_path(run_dir);
    let loaded = load_runner_state_repo(
        runner_repository_for_path(legacy_path.clone()),
        &legacy_path,
    )?;
    if let Some(state) = loaded.as_ref() {
        runner_repository(run_dir).save(state)?;
    }
    Ok(loaded)
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
    if !current_path.exists() && legacy_runner_state_path(run_dir).exists() {
        let _ = read_runner_state(run_dir)?;
    }

    let desired = state.clone();
    let updated = runner_repository(run_dir).update(|current| {
        let Some(current) = current else {
            return Err(CliErrorKind::concurrent_modification(cow!(
                "missing runner state while applying {}",
                desired.last_event.as_deref().unwrap_or("runner transition")
            ))
            .with_details(format!(
                "Re-run `harness init` or reload {} before retrying.",
                current_path.display()
            )));
        };
        if current.transition_count != expected_transition_count {
            return Err(CliErrorKind::concurrent_modification(cow!(
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

fn load_runner_state_repo(
    repo: VersionedJsonRepository<RunnerWorkflowState>,
    path: &Path,
) -> Result<Option<RunnerWorkflowState>, CliError> {
    match repo.load() {
        Ok(loaded) => Ok(loaded),
        Err(error) if error.code() == "WORKFLOW_VERSION" => Err(CliErrorKind::workflow_version(
            cow!("runner state requires schema version 2"),
        )
        .with_details(format!(
            "{}\nDelete {} or re-run `harness init` to regenerate the runner state.",
            error.message(),
            path.display()
        ))),
        Err(error) => Err(error),
    }
}

#[derive(Debug, Deserialize)]
struct RunnerWorkflowStateV1 {
    pub phase: RunnerPhase,
    pub preflight: PreflightState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure: Option<FailureState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_fix: Option<SuiteFixState>,
    pub updated_at: String,
    pub transition_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_event: Option<String>,
}

fn migrate_runner_v1_to_v2(data: Value) -> Result<Value, CliError> {
    let v1: RunnerWorkflowStateV1 = serde_json::from_value(data).map_err(|error| -> CliError {
        CliErrorKind::workflow_parse(cow!("failed to parse runner workflow v1: {error}")).into()
    })?;
    let v2 = RunnerWorkflowStateRecord {
        schema_version: RUNNER_STATE_SCHEMA_VERSION,
        state: RunnerWorkflowPayload {
            phase: v1.phase,
            preflight: v1.preflight,
            failure: v1.failure,
            suite_fix: v1.suite_fix,
        },
        updated_at: v1.updated_at,
        transition_count: v1.transition_count,
        last_event: v1.last_event,
    };
    serde_json::to_value(v2).map_err(|error| -> CliError {
        CliErrorKind::workflow_serialize(cow!("failed to serialize runner workflow v2: {error}"))
            .into()
    })
}

#[cfg(test)]
mod tests {
    use std::fs;

    use serde_json::json;
    use tempfile::TempDir;

    use super::*;
    use crate::workflow::runner::{ManifestFixDecision, SuiteFixState};

    #[test]
    fn read_runner_state_migrates_flat_v1_state() {
        let dir = TempDir::new().unwrap();
        let path = runner_state_path(dir.path());
        let v1 = json!({
            "schema_version": 1,
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

        let state = read_runner_state(dir.path()).unwrap().unwrap();
        assert_eq!(state.schema_version, 2);
        assert_eq!(state.phase, RunnerPhase::Triage);
        assert_eq!(state.transition_count, 4);

        let on_disk: Value = serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap();
        assert_eq!(on_disk["schema_version"], 2);
        assert_eq!(on_disk["state"]["phase"], "triage");
    }

    #[test]
    fn read_runner_state_migrates_legacy_file_name() {
        let dir = TempDir::new().unwrap();
        let legacy_path = legacy_runner_state_path(dir.path());
        let v1 = json!({
            "schema_version": 1,
            "phase": "bootstrap",
            "preflight": { "status": "pending" },
            "updated_at": "2025-01-01T00:00:00Z",
            "transition_count": 0,
            "last_event": "RunInitialized"
        });
        fs::write(&legacy_path, serde_json::to_string_pretty(&v1).unwrap()).unwrap();

        let state = read_runner_state(dir.path()).unwrap().unwrap();
        assert_eq!(state.schema_version, 2);
        assert!(runner_state_path(dir.path()).exists());
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

        let mut next = state.clone();
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
