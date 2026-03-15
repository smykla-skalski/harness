use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::workflow::engine::{TransitionError, VersionedJsonRepository};

/// Runner workflow phases with associated state data.
///
/// Each variant carries only the data valid for that phase.
/// `FailureState` only exists inside `Triage`, `PreflightStatus`
/// only inside `Preflight`. Invalid combinations are unrepresentable.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "name", rename_all = "snake_case")]
#[non_exhaustive]
pub enum RunnerPhase {
    Bootstrap,
    Preflight {
        status: PreflightStatus,
    },
    Execution,
    Triage {
        failure: FailureState,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        suite_fix: Option<SuiteFixState>,
    },
    Closeout,
    Completed,
    Aborted,
    Suspended,
}

impl RunnerPhase {
    /// Short lowercase name for display and CLI output.
    #[must_use]
    pub fn name(&self) -> &'static str {
        match self {
            Self::Bootstrap => "bootstrap",
            Self::Preflight { .. } => "preflight",
            Self::Execution => "execution",
            Self::Triage { .. } => "triage",
            Self::Closeout => "closeout",
            Self::Completed => "completed",
            Self::Aborted => "aborted",
            Self::Suspended => "suspended",
        }
    }
}

/// Typed events for runner state transitions.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum RunnerEvent {
    RunInitialized,
    PreflightStarted,
    PreflightCaptured,
    PreflightFailed,
    RunStarted,
    FailureTriageRequested,
    FailureRecorded,
    SuiteFixApproved,
    ManifestFixAnswered,
    RunCompleted,
    RunAborted,
    RunSuspended,
    RunResumed,
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
    pub updated_at: String,
    pub transition_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_event: Option<RunnerEvent>,
}

const RUNNER_STATE_SCHEMA_VERSION: u32 = 2;

impl RunnerWorkflowState {
    /// Apply a state transition, returning the new state.
    ///
    /// Validates the transition, increments the counter, and stamps
    /// the current time.
    ///
    /// # Errors
    /// Returns `TransitionError` if the transition is not allowed.
    pub fn transition(
        &self,
        event: RunnerEvent,
        new_phase: RunnerPhase,
    ) -> Result<Self, TransitionError> {
        if !self.can_transition(&new_phase) {
            return Err(TransitionError(format!(
                "invalid transition from {} to {}",
                self.phase.name(),
                new_phase.name(),
            )));
        }
        Ok(Self {
            schema_version: self.schema_version,
            phase: new_phase,
            updated_at: now_utc(),
            transition_count: self.transition_count + 1,
            last_event: Some(event),
        })
    }

    /// Check whether a transition to `target` is allowed.
    #[must_use]
    pub fn can_transition(&self, target: &RunnerPhase) -> bool {
        matches!(
            (&self.phase, target),
            (RunnerPhase::Bootstrap, RunnerPhase::Preflight { .. })
                | (
                    RunnerPhase::Preflight { .. },
                    RunnerPhase::Preflight { .. } | RunnerPhase::Execution,
                )
                | (
                    RunnerPhase::Execution,
                    RunnerPhase::Triage { .. } | RunnerPhase::Closeout,
                )
                | (
                    RunnerPhase::Triage { .. },
                    RunnerPhase::Triage { .. }
                        | RunnerPhase::Execution
                        | RunnerPhase::Closeout
                        | RunnerPhase::Suspended,
                )
                | (RunnerPhase::Suspended, RunnerPhase::Execution)
                | (RunnerPhase::Closeout, RunnerPhase::Completed)
                | (_, RunnerPhase::Aborted)
        )
    }
}

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
        updated_at: occurred_at.to_string(),
        transition_count: 0,
        last_event: Some(RunnerEvent::RunInitialized),
    }
}

fn save_state(run_dir: &Path, state: &RunnerWorkflowState) -> Result<(), CliError> {
    let repo = runner_repository(run_dir);
    let value = serde_json::to_value(state).map_err(|e| CliError {
        code: "WORKFLOW_SERIALIZE".into(),
        message: format!("failed to serialize runner state: {e}"),
        exit_code: 5,
        hint: None,
        details: None,
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
                serde_json::from_value(value).map_err(|e| CliError {
                    code: "WORKFLOW_PARSE".into(),
                    message: format!("failed to parse runner state: {e}"),
                    exit_code: 5,
                    hint: None,
                    details: None,
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
    match &state.phase {
        RunnerPhase::Bootstrap => "Resume the run by finishing cluster bootstrap before preflight.",
        RunnerPhase::Preflight { status } => {
            if *status == PreflightStatus::Running {
                "Finish the guarded preflight worker flow, then validate the saved artifacts."
            } else {
                "Resume the run by executing `harness preflight` before starting group execution."
            }
        }
        RunnerPhase::Triage { suite_fix, .. } => {
            if suite_fix.is_some() {
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
        assert_eq!(json["phase"]["name"], "bootstrap");
        let loaded: RunnerWorkflowState = serde_json::from_value(json).unwrap();
        assert_eq!(loaded.phase, RunnerPhase::Bootstrap);
    }

    #[test]
    fn phase_with_data_serialization() {
        let phase = RunnerPhase::Preflight {
            status: PreflightStatus::Running,
        };
        let json = serde_json::to_value(&phase).unwrap();
        assert_eq!(json["name"], "preflight");
        assert_eq!(json["status"], "running");
        let loaded: RunnerPhase = serde_json::from_value(json).unwrap();
        assert_eq!(
            loaded,
            RunnerPhase::Preflight {
                status: PreflightStatus::Running
            }
        );
    }

    #[test]
    fn triage_phase_serialization() {
        let phase = RunnerPhase::Triage {
            failure: FailureState {
                kind: FailureKind::Manifest,
                suite_target: Some("groups/g1".to_string()),
                message: None,
            },
            suite_fix: None,
        };
        let json = serde_json::to_value(&phase).unwrap();
        assert_eq!(json["name"], "triage");
        assert_eq!(json["failure"]["kind"], "manifest");
        assert_eq!(json["failure"]["suite_target"], "groups/g1");
        assert!(json.get("suite_fix").is_none());
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
        let state = bootstrap_state();
        let new_state = state
            .transition(
                RunnerEvent::PreflightStarted,
                RunnerPhase::Preflight {
                    status: PreflightStatus::Pending,
                },
            )
            .unwrap();
        write_runner_state(dir.path(), &new_state).unwrap();
        let loaded = read_runner_state(dir.path()).unwrap().unwrap();
        assert_eq!(
            loaded.phase,
            RunnerPhase::Preflight {
                status: PreflightStatus::Pending
            }
        );
        assert_eq!(loaded.transition_count, 1);
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
        let state = bootstrap_state();
        assert!(next_action(Some(&state)).contains("bootstrap"));

        let preflight = RunnerWorkflowState {
            phase: RunnerPhase::Preflight {
                status: PreflightStatus::Pending,
            },
            ..state.clone()
        };
        assert!(next_action(Some(&preflight)).contains("preflight"));

        let running = RunnerWorkflowState {
            phase: RunnerPhase::Preflight {
                status: PreflightStatus::Running,
            },
            ..state.clone()
        };
        assert!(next_action(Some(&running)).contains("preflight worker"));

        let execution = RunnerWorkflowState {
            phase: RunnerPhase::Execution,
            ..state.clone()
        };
        assert!(next_action(Some(&execution)).contains("execution"));

        let triage = RunnerWorkflowState {
            phase: RunnerPhase::Triage {
                failure: FailureState {
                    kind: FailureKind::Manifest,
                    suite_target: None,
                    message: None,
                },
                suite_fix: None,
            },
            ..state.clone()
        };
        assert!(next_action(Some(&triage)).contains("triage"));

        let closeout = RunnerWorkflowState {
            phase: RunnerPhase::Closeout,
            ..state.clone()
        };
        assert!(next_action(Some(&closeout)).contains("closeout"));

        let completed = RunnerWorkflowState {
            phase: RunnerPhase::Completed,
            ..state.clone()
        };
        assert!(next_action(Some(&completed)).contains("final verdict"));

        let aborted = RunnerWorkflowState {
            phase: RunnerPhase::Aborted,
            ..state.clone()
        };
        assert!(next_action(Some(&aborted)).contains("guard-stop"));

        let suspended = RunnerWorkflowState {
            phase: RunnerPhase::Suspended,
            ..state
        };
        assert!(next_action(Some(&suspended)).contains("suspended"));
    }

    #[test]
    fn next_action_triage_with_suite_fix() {
        let state = RunnerWorkflowState {
            schema_version: RUNNER_STATE_SCHEMA_VERSION,
            phase: RunnerPhase::Triage {
                failure: FailureState {
                    kind: FailureKind::Manifest,
                    suite_target: None,
                    message: None,
                },
                suite_fix: Some(SuiteFixState {
                    approved_paths: vec![],
                    suite_written: false,
                    amendments_written: false,
                    decision: ManifestFixDecision::SuiteAndRun,
                }),
            },
            updated_at: "2025-01-01T00:00:00Z".to_string(),
            transition_count: 0,
            last_event: None,
        };
        assert!(next_action(Some(&state)).contains("suite repair"));
    }

    #[test]
    fn runner_state_path_builds_correctly() {
        let path = runner_state_path(Path::new("/runs/r1"));
        assert_eq!(path, PathBuf::from("/runs/r1/suite-runner-state.json"));
    }

    #[test]
    fn full_state_serialization_with_triage() {
        let state = RunnerWorkflowState {
            schema_version: 2,
            phase: RunnerPhase::Triage {
                failure: FailureState {
                    kind: FailureKind::Manifest,
                    suite_target: Some("groups/g1".to_string()),
                    message: Some("test failed".to_string()),
                },
                suite_fix: Some(SuiteFixState {
                    approved_paths: vec!["groups/g1".to_string()],
                    suite_written: true,
                    amendments_written: false,
                    decision: ManifestFixDecision::SuiteAndRun,
                }),
            },
            updated_at: "2025-01-01T00:00:00Z".to_string(),
            transition_count: 5,
            last_event: Some(RunnerEvent::ManifestFixAnswered),
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

    #[test]
    fn runner_event_serialization() {
        let json = serde_json::to_value(RunnerEvent::FailureTriageRequested).unwrap();
        assert_eq!(json, "failure_triage_requested");
        let loaded: RunnerEvent = serde_json::from_value(json).unwrap();
        assert_eq!(loaded, RunnerEvent::FailureTriageRequested);
    }

    #[test]
    fn phase_name_returns_correct_string() {
        assert_eq!(RunnerPhase::Bootstrap.name(), "bootstrap");
        assert_eq!(
            RunnerPhase::Preflight {
                status: PreflightStatus::Pending
            }
            .name(),
            "preflight"
        );
        assert_eq!(RunnerPhase::Execution.name(), "execution");
        assert_eq!(
            RunnerPhase::Triage {
                failure: FailureState {
                    kind: FailureKind::Manifest,
                    suite_target: None,
                    message: None,
                },
                suite_fix: None,
            }
            .name(),
            "triage"
        );
    }

    // Transition validation tests
    #[test]
    fn transition_bootstrap_to_preflight() {
        let state = bootstrap_state();
        let result = state.transition(
            RunnerEvent::PreflightStarted,
            RunnerPhase::Preflight {
                status: PreflightStatus::Pending,
            },
        );
        assert!(result.is_ok());
        let new = result.unwrap();
        assert_eq!(new.transition_count, 1);
        assert_eq!(new.last_event, Some(RunnerEvent::PreflightStarted));
    }

    #[test]
    fn transition_rejects_bootstrap_to_execution() {
        let state = bootstrap_state();
        let result = state.transition(RunnerEvent::RunStarted, RunnerPhase::Execution);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.to_string().contains("bootstrap"));
        assert!(err.to_string().contains("execution"));
    }

    #[test]
    fn transition_rejects_bootstrap_to_completed() {
        let state = bootstrap_state();
        let result = state.transition(RunnerEvent::RunCompleted, RunnerPhase::Completed);
        assert!(result.is_err());
    }

    #[test]
    fn transition_any_to_aborted() {
        let state = bootstrap_state();
        let result = state.transition(RunnerEvent::RunAborted, RunnerPhase::Aborted);
        assert!(result.is_ok());
    }

    #[test]
    fn transition_preflight_to_preflight() {
        let state = RunnerWorkflowState {
            phase: RunnerPhase::Preflight {
                status: PreflightStatus::Pending,
            },
            ..bootstrap_state()
        };
        let result = state.transition(
            RunnerEvent::PreflightFailed,
            RunnerPhase::Preflight {
                status: PreflightStatus::Pending,
            },
        );
        assert!(result.is_ok());
    }

    #[test]
    fn transition_execution_to_triage() {
        let state = RunnerWorkflowState {
            phase: RunnerPhase::Execution,
            ..bootstrap_state()
        };
        let result = state.transition(
            RunnerEvent::FailureTriageRequested,
            RunnerPhase::Triage {
                failure: FailureState {
                    kind: FailureKind::Manifest,
                    suite_target: None,
                    message: None,
                },
                suite_fix: None,
            },
        );
        assert!(result.is_ok());
    }

    #[test]
    fn transition_triage_to_execution() {
        let state = RunnerWorkflowState {
            phase: RunnerPhase::Triage {
                failure: FailureState {
                    kind: FailureKind::Manifest,
                    suite_target: None,
                    message: None,
                },
                suite_fix: None,
            },
            ..bootstrap_state()
        };
        let result = state.transition(RunnerEvent::RunResumed, RunnerPhase::Execution);
        assert!(result.is_ok());
    }

    #[test]
    fn can_transition_validates_graph() {
        let state = bootstrap_state();
        assert!(state.can_transition(&RunnerPhase::Preflight {
            status: PreflightStatus::Pending,
        }));
        assert!(!state.can_transition(&RunnerPhase::Execution));
        assert!(!state.can_transition(&RunnerPhase::Completed));
        // Any state can abort
        assert!(state.can_transition(&RunnerPhase::Aborted));
    }
}
