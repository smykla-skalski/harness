use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::workflow::engine::VersionedJsonRepository;

/// Runner workflow phases.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum RunnerPhase {
    Bootstrap,
    Preflight,
    Execution,
    Triage,
    Closeout,
    Completed,
    Aborted,
    Suspended,
}

/// Preflight status within the runner workflow.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum PreflightStatus {
    Pending,
    Running,
    Complete,
}

/// Kind of failure in the runner workflow.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[non_exhaustive]
#[serde(rename_all = "snake_case")]
pub enum FailureKind {
    Manifest,
    Environment,
    Product,
}

#[non_exhaustive]
/// Manifest fix decision from the user.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ManifestFixDecision {
    #[serde(rename = "Fix for this run only")]
    RunOnly,
    #[serde(rename = "Fix in suite and this run")]
    SuiteAndRun,
    #[serde(rename = "Skip this step")]
    SkipStep,
    #[serde(rename = "Stop run")]
    StopRun,
}

/// Preflight sub-state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreflightState {
    pub status: PreflightStatus,
}

/// Failure sub-state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FailureState {
    pub kind: FailureKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_target: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

/// Suite fix sub-state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SuiteFixState {
    pub approved_paths: Vec<String>,
    #[serde(default)]
    pub suite_written: bool,
    #[serde(default)]
    pub amendments_written: bool,
    pub decision: ManifestFixDecision,
}

impl SuiteFixState {
    #[must_use]
    pub fn ready_to_resume(&self) -> bool {
        self.suite_written && self.amendments_written
    }
}

/// Full runner workflow state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunnerWorkflowState {
    pub schema_version: u32,
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

const RUNNER_STATE_SCHEMA_VERSION: u32 = 1;

/// Path to the runner state file.
#[must_use]
pub fn runner_state_path(run_dir: &Path) -> PathBuf {
    run_dir.join("suite-runner-state.json")
}

fn runner_repository(run_dir: &Path) -> VersionedJsonRepository {
    VersionedJsonRepository::new(runner_state_path(run_dir), RUNNER_STATE_SCHEMA_VERSION)
}

fn now_utc() -> String {
    chrono::Utc::now().to_rfc3339()
}

fn make_initial_state(occurred_at: &str) -> RunnerWorkflowState {
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

fn save_state(run_dir: &Path, state: &RunnerWorkflowState) -> Result<(), CliError> {
    let repo = runner_repository(run_dir);
    let value = serde_json::to_value(state).map_err(|e| -> CliError {
        CliErrorKind::WorkflowSerialize {
            detail: format!("failed to serialize runner state: {e}"),
        }
        .into()
    })?;
    repo.save(&value)?;
    Ok(())
}

/// Initialize runner state for a new run.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn initialize_runner_state(run_dir: &Path) -> Result<RunnerWorkflowState, CliError> {
    let state = make_initial_state(&now_utc());
    save_state(run_dir, &state)?;
    Ok(state)
}

/// Read runner state from disk.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn read_runner_state(run_dir: &Path) -> Result<Option<RunnerWorkflowState>, CliError> {
    let repo = runner_repository(run_dir);
    match repo.load()? {
        Some(value) => {
            let state: RunnerWorkflowState =
                serde_json::from_value(value).map_err(|e| -> CliError {
                    CliErrorKind::WorkflowParse {
                        detail: format!("failed to parse runner state: {e}"),
                    }
                    .into()
                })?;
            Ok(Some(state))
        }
        None => Ok(None),
    }
}

/// Write runner state to disk.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn write_runner_state(run_dir: &Path, state: &RunnerWorkflowState) -> Result<(), CliError> {
    save_state(run_dir, state)
}

/// Get the next action hint based on runner state.
#[must_use]
pub fn next_action(state: Option<&RunnerWorkflowState>) -> &'static str {
    let Some(state) = state else {
        return "Reload the saved suite-runner state before continuing.";
    };
    match state.phase {
        RunnerPhase::Bootstrap => "Resume the run by finishing cluster bootstrap before preflight.",
        RunnerPhase::Preflight => {
            if state.preflight.status == PreflightStatus::Running {
                "Finish the guarded preflight worker flow, then validate the saved artifacts."
            } else {
                "Resume the run by executing `harness preflight` before starting group execution."
            }
        }
        RunnerPhase::Triage => {
            if state.suite_fix.is_some() {
                "Finish the approved suite repair and `amendments.md`, then continue the run."
            } else {
                "Resolve the current failure triage decision before continuing the run."
            }
        }
        RunnerPhase::Closeout => {
            "Finish closeout and report verification from the saved run context."
        }
        RunnerPhase::Completed => {
            "The run already reached a final verdict. Review the saved report and closeout artifacts."
        }
        RunnerPhase::Suspended => {
            "Run is suspended. Resume with `harness runner-state --event resume-run` \
             and continue from the saved `next_planned_group`."
        }
        RunnerPhase::Aborted => {
            "Do not blame the user for `guard-stop` feedback. If the stop was unexpected, \
             run `harness runner-state --event resume-run`, do not edit `run-status.json` \
             or `run-report.md`, and continue from the saved `next_planned_group`. \
             If the run was intentionally halted, keep the aborted report as-is."
        }
        RunnerPhase::Execution => "Continue the run from the saved execution context.",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn bootstrap_state() -> RunnerWorkflowState {
        make_initial_state("2025-01-01T00:00:00Z")
    }

    #[test]
    fn runner_phase_serialization_round_trip() {
        let state = bootstrap_state();
        let json = serde_json::to_value(&state).unwrap();
        assert_eq!(json["phase"], "bootstrap");
        assert_eq!(json["preflight"]["status"], "pending");
        let loaded: RunnerWorkflowState = serde_json::from_value(json).unwrap();
        assert_eq!(loaded.phase, RunnerPhase::Bootstrap);
    }

    #[test]
    fn failure_kind_serialization() {
        let f = FailureState {
            kind: FailureKind::Manifest,
            suite_target: Some("groups/g1".to_string()),
            message: None,
        };
        let json = serde_json::to_value(&f).unwrap();
        assert_eq!(json["kind"], "manifest");
        assert_eq!(json["suite_target"], "groups/g1");
        assert!(json.get("message").is_none());
    }

    #[test]
    fn manifest_fix_decision_serialization() {
        let json = serde_json::to_value(ManifestFixDecision::SuiteAndRun).unwrap();
        assert_eq!(json, "Fix in suite and this run");
        let loaded: ManifestFixDecision = serde_json::from_value(json).unwrap();
        assert_eq!(loaded, ManifestFixDecision::SuiteAndRun);
    }

    #[test]
    fn suite_fix_ready_to_resume_both_true() {
        let fix = SuiteFixState {
            approved_paths: vec!["a".to_string()],
            suite_written: true,
            amendments_written: true,
            decision: ManifestFixDecision::SuiteAndRun,
        };
        assert!(fix.ready_to_resume());
    }

    #[test]
    fn suite_fix_not_ready_when_partial() {
        let fix = SuiteFixState {
            approved_paths: vec![],
            suite_written: true,
            amendments_written: false,
            decision: ManifestFixDecision::SuiteAndRun,
        };
        assert!(!fix.ready_to_resume());
    }

    #[test]
    fn initialize_and_read_round_trip() {
        let dir = TempDir::new().unwrap();
        let state = initialize_runner_state(dir.path()).unwrap();
        assert_eq!(state.phase, RunnerPhase::Bootstrap);
        assert_eq!(state.transition_count, 0);
        let loaded = read_runner_state(dir.path()).unwrap().unwrap();
        assert_eq!(loaded.phase, RunnerPhase::Bootstrap);
    }

    #[test]
    fn write_and_read_runner_state() {
        let dir = TempDir::new().unwrap();
        let mut state = bootstrap_state();
        state.phase = RunnerPhase::Execution;
        state.transition_count = 3;
        write_runner_state(dir.path(), &state).unwrap();
        let loaded = read_runner_state(dir.path()).unwrap().unwrap();
        assert_eq!(loaded.phase, RunnerPhase::Execution);
        assert_eq!(loaded.transition_count, 3);
    }

    #[test]
    fn read_returns_none_when_missing() {
        let dir = TempDir::new().unwrap();
        assert!(read_runner_state(dir.path()).unwrap().is_none());
    }

    #[test]
    fn next_action_none_state() {
        let action = next_action(None);
        assert!(action.contains("Reload"));
    }

    #[test]
    fn next_action_each_phase() {
        let mut state = bootstrap_state();
        assert!(next_action(Some(&state)).contains("bootstrap"));

        state.phase = RunnerPhase::Preflight;
        assert!(next_action(Some(&state)).contains("preflight"));

        state.preflight.status = PreflightStatus::Running;
        assert!(next_action(Some(&state)).contains("preflight worker"));

        state.phase = RunnerPhase::Execution;
        assert!(next_action(Some(&state)).contains("execution"));

        state.phase = RunnerPhase::Triage;
        assert!(next_action(Some(&state)).contains("triage"));

        state.phase = RunnerPhase::Closeout;
        assert!(next_action(Some(&state)).contains("closeout"));

        state.phase = RunnerPhase::Completed;
        assert!(next_action(Some(&state)).contains("final verdict"));

        state.phase = RunnerPhase::Aborted;
        assert!(next_action(Some(&state)).contains("guard-stop"));

        state.phase = RunnerPhase::Suspended;
        assert!(next_action(Some(&state)).contains("suspended"));
    }

    #[test]
    fn next_action_triage_with_suite_fix() {
        let mut state = bootstrap_state();
        state.phase = RunnerPhase::Triage;
        state.suite_fix = Some(SuiteFixState {
            approved_paths: vec![],
            suite_written: false,
            amendments_written: false,
            decision: ManifestFixDecision::SuiteAndRun,
        });
        assert!(next_action(Some(&state)).contains("suite repair"));
    }

    #[test]
    fn runner_state_path_builds_correctly() {
        let path = runner_state_path(Path::new("/runs/r1"));
        assert_eq!(path, PathBuf::from("/runs/r1/suite-runner-state.json"));
    }

    #[test]
    fn full_state_serialization_with_all_fields() {
        let state = RunnerWorkflowState {
            schema_version: 1,
            phase: RunnerPhase::Triage,
            preflight: PreflightState {
                status: PreflightStatus::Complete,
            },
            failure: Some(FailureState {
                kind: FailureKind::Manifest,
                suite_target: Some("groups/g1".to_string()),
                message: Some("test failed".to_string()),
            }),
            suite_fix: Some(SuiteFixState {
                approved_paths: vec!["groups/g1".to_string()],
                suite_written: true,
                amendments_written: false,
                decision: ManifestFixDecision::SuiteAndRun,
            }),
            updated_at: "2025-01-01T00:00:00Z".to_string(),
            transition_count: 5,
            last_event: Some("ManifestFixAnswered".to_string()),
        };
        let json = serde_json::to_value(&state).unwrap();
        let loaded: RunnerWorkflowState = serde_json::from_value(json).unwrap();
        assert_eq!(loaded, state);
    }

    #[test]
    fn preflight_status_variants_serialize() {
        for (variant, expected) in [
            (PreflightStatus::Pending, "pending"),
            (PreflightStatus::Running, "running"),
            (PreflightStatus::Complete, "complete"),
        ] {
            let json = serde_json::to_value(variant).unwrap();
            assert_eq!(json, expected);
        }
    }

    #[test]
    fn failure_kind_variants_serialize() {
        for (variant, expected) in [
            (FailureKind::Manifest, "manifest"),
            (FailureKind::Environment, "environment"),
            (FailureKind::Product, "product"),
        ] {
            let json = serde_json::to_value(variant).unwrap();
            assert_eq!(json, expected);
        }
    }

    #[test]
    fn manifest_fix_decision_all_variants() {
        let cases = [
            (ManifestFixDecision::RunOnly, "Fix for this run only"),
            (
                ManifestFixDecision::SuiteAndRun,
                "Fix in suite and this run",
            ),
            (ManifestFixDecision::SkipStep, "Skip this step"),
            (ManifestFixDecision::StopRun, "Stop run"),
        ];
        for (variant, expected) in cases {
            let json = serde_json::to_value(variant).unwrap();
            assert_eq!(json, expected);
        }
    }
}
