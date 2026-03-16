use std::fmt;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind, cow};
use crate::rules::skill_dirs;
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

impl fmt::Display for RunnerPhase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Bootstrap => "bootstrap",
            Self::Preflight => "preflight",
            Self::Execution => "execution",
            Self::Triage => "triage",
            Self::Closeout => "closeout",
            Self::Completed => "completed",
            Self::Aborted => "aborted",
            Self::Suspended => "suspended",
        })
    }
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
    run_dir.join(skill_dirs::RUN_STATE_FILE)
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
        CliErrorKind::workflow_serialize(cow!("failed to serialize runner state: {e}")).into()
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
                    CliErrorKind::workflow_parse(cow!("failed to parse runner state: {e}")).into()
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

/// Apply a named event to the runner state, advancing the phase when valid.
///
/// Returns the updated state after persisting to disk. Invalid transitions
/// produce `CliErrorKind::InvalidTransition`.
///
/// # Errors
/// Returns `CliError` on invalid transition or IO failure.
pub fn apply_event(
    run_dir: &Path,
    event: &str,
    suite_target: Option<&str>,
    message: Option<&str>,
) -> Result<RunnerWorkflowState, CliError> {
    let mut state = read_runner_state(run_dir)?.unwrap_or_else(|| make_initial_state(&now_utc()));

    let new_phase = resolve_transition(&state, event, suite_target, message)?;
    state.phase = new_phase;
    state.transition_count += 1;
    state.updated_at = now_utc();
    state.last_event = Some(event_label(event));

    // Clear failure/suite_fix on forward movement out of triage.
    if new_phase != RunnerPhase::Triage {
        if state.failure.is_some() && !matches!(new_phase, RunnerPhase::Aborted) {
            state.failure = None;
        }
        if state.suite_fix.is_some() {
            state.suite_fix = None;
        }
    }

    // Set preflight sub-state on preflight events.
    match event {
        "preflight-started" => state.preflight.status = PreflightStatus::Running,
        "preflight-captured" => state.preflight.status = PreflightStatus::Complete,
        _ => {}
    }

    // Set failure on failure-manifest.
    if event == "failure-manifest" {
        state.failure = Some(FailureState {
            kind: FailureKind::Manifest,
            suite_target: suite_target.map(str::to_string),
            message: message.map(str::to_string),
        });
    }

    // Set suite_fix on manifest-fix decisions that enter triage.
    if event.starts_with("manifest-fix-") && new_phase == RunnerPhase::Triage {
        let decision = match event {
            "manifest-fix-suite-and-run" => ManifestFixDecision::SuiteAndRun,
            "manifest-fix-skip-step" => ManifestFixDecision::SkipStep,
            "manifest-fix-stop-run" => ManifestFixDecision::StopRun,
            // manifest-fix-run-only and any other prefix match.
            _ => ManifestFixDecision::RunOnly,
        };
        state.suite_fix = Some(SuiteFixState {
            approved_paths: suite_target.map_or_else(Vec::new, |s| vec![s.to_string()]),
            suite_written: false,
            amendments_written: false,
            decision,
        });
    }

    save_state(run_dir, &state)?;
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
    let Some(mut state) = read_runner_state(run_dir)? else {
        return Ok(false);
    };
    if matches!(state.phase, RunnerPhase::Bootstrap | RunnerPhase::Preflight) {
        state.phase = RunnerPhase::Execution;
        state.transition_count += 1;
        state.updated_at = now_utc();
        state.last_event = Some("AutoAdvanceToExecution".to_string());
        save_state(run_dir, &state)?;
        return Ok(true);
    }
    Ok(false)
}

/// Map an event name to the target phase, validating that the transition
/// is legal from the current phase.
fn resolve_transition(
    state: &RunnerWorkflowState,
    event: &str,
    _suite_target: Option<&str>,
    _message: Option<&str>,
) -> Result<RunnerPhase, CliError> {
    let current = state.phase;
    let target = match event {
        "cluster-prepared" | "preflight-started" => RunnerPhase::Preflight,
        "preflight-captured" | "suite-fix-resumed" | "resume-run" => RunnerPhase::Execution,
        "preflight-failed"
        | "failure-manifest"
        | "manifest-fix-run-only"
        | "manifest-fix-suite-and-run"
        | "manifest-fix-skip-step" => RunnerPhase::Triage,
        "manifest-fix-stop-run" | "abort" => RunnerPhase::Aborted,
        "suspend" => RunnerPhase::Suspended,
        "closeout-started" => RunnerPhase::Closeout,
        "run-completed" => RunnerPhase::Completed,
        other => {
            return Err(CliErrorKind::invalid_transition(format!("unknown event: {other}")).into());
        }
    };

    // Validate the transition is legal.
    if !is_valid_transition(current, target, event) {
        return Err(CliErrorKind::invalid_transition(format!(
            "cannot apply '{event}' in phase {current} (target: {target})"
        ))
        .into());
    }

    Ok(target)
}

/// Check whether a phase transition is allowed.
fn is_valid_transition(from: RunnerPhase, to: RunnerPhase, event: &str) -> bool {
    // Abort and suspend are allowed from any non-terminal phase.
    if matches!(to, RunnerPhase::Aborted | RunnerPhase::Suspended) {
        return !matches!(from, RunnerPhase::Completed);
    }
    // Resume is only valid from suspended or aborted.
    if event == "resume-run" {
        return matches!(from, RunnerPhase::Suspended | RunnerPhase::Aborted);
    }
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

/// Produce a human-readable label for a workflow event.
fn event_label(event: &str) -> String {
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
}

/// Next action for a runner workflow state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunnerNextAction {
    ReloadState,
    FinishBootstrap,
    FinishPreflightWorker,
    ExecutePreflight,
    ContinueExecution,
    FinishSuiteRepair,
    ResolveTriage,
    FinishCloseout,
    ReviewReport,
    ResumeRun,
    HandleAbort,
}

impl fmt::Display for RunnerNextAction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::ReloadState => {
                "Reload the saved suite:run state before continuing."
            }
            Self::FinishBootstrap => {
                "Resume the run by finishing cluster bootstrap before preflight."
            }
            Self::FinishPreflightWorker => {
                "Finish the guarded preflight worker flow, then validate the saved artifacts."
            }
            Self::ExecutePreflight => {
                "Resume the run by executing `harness preflight` before starting group execution."
            }
            Self::ContinueExecution => "Continue the run from the saved execution context.",
            Self::FinishSuiteRepair => {
                "Finish the approved suite repair and `amendments.md`, then continue the run."
            }
            Self::ResolveTriage => {
                "Resolve the current failure triage decision before continuing the run."
            }
            Self::FinishCloseout => {
                "Finish closeout and report verification from the saved run context."
            }
            Self::ReviewReport => {
                "The run already reached a final verdict. Review the saved report and closeout artifacts."
            }
            Self::ResumeRun => {
                "Run is suspended. Resume with `harness runner-state --event resume-run` \
                 and continue from the saved `next_planned_group`."
            }
            Self::HandleAbort => {
                "Do not blame the user for `guard-stop` feedback. If the stop was unexpected, \
                 run `harness runner-state --event resume-run`, do not edit `run-status.json` \
                 or `run-report.md`, and continue from the saved `next_planned_group`. \
                 If the run was intentionally halted, keep the aborted report as-is."
            }
        })
    }
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
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn bootstrap_state() -> RunnerWorkflowState {
        make_initial_state("2025-01-01T00:00:00Z")
    }

    #[test]
    fn runner_phase_display() {
        let cases = [
            (RunnerPhase::Bootstrap, "bootstrap"),
            (RunnerPhase::Preflight, "preflight"),
            (RunnerPhase::Execution, "execution"),
            (RunnerPhase::Triage, "triage"),
            (RunnerPhase::Closeout, "closeout"),
            (RunnerPhase::Completed, "completed"),
            (RunnerPhase::Aborted, "aborted"),
            (RunnerPhase::Suspended, "suspended"),
        ];
        for (variant, expected) in cases {
            assert_eq!(variant.to_string(), expected);
        }
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
        assert_eq!(next_action(None), RunnerNextAction::ReloadState);
        assert!(next_action(None).to_string().contains("Reload"));
    }

    #[test]
    fn next_action_each_phase() {
        let mut state = bootstrap_state();
        assert_eq!(next_action(Some(&state)), RunnerNextAction::FinishBootstrap);
        assert!(next_action(Some(&state)).to_string().contains("bootstrap"));

        state.phase = RunnerPhase::Preflight;
        assert_eq!(
            next_action(Some(&state)),
            RunnerNextAction::ExecutePreflight
        );
        assert!(next_action(Some(&state)).to_string().contains("preflight"));

        state.preflight.status = PreflightStatus::Running;
        assert_eq!(
            next_action(Some(&state)),
            RunnerNextAction::FinishPreflightWorker
        );
        assert!(
            next_action(Some(&state))
                .to_string()
                .contains("preflight worker")
        );

        state.phase = RunnerPhase::Execution;
        assert_eq!(
            next_action(Some(&state)),
            RunnerNextAction::ContinueExecution
        );
        assert!(next_action(Some(&state)).to_string().contains("execution"));

        state.phase = RunnerPhase::Triage;
        assert_eq!(next_action(Some(&state)), RunnerNextAction::ResolveTriage);
        assert!(next_action(Some(&state)).to_string().contains("triage"));

        state.phase = RunnerPhase::Closeout;
        assert_eq!(next_action(Some(&state)), RunnerNextAction::FinishCloseout);
        assert!(next_action(Some(&state)).to_string().contains("closeout"));

        state.phase = RunnerPhase::Completed;
        assert_eq!(next_action(Some(&state)), RunnerNextAction::ReviewReport);
        assert!(
            next_action(Some(&state))
                .to_string()
                .contains("final verdict")
        );

        state.phase = RunnerPhase::Aborted;
        assert_eq!(next_action(Some(&state)), RunnerNextAction::HandleAbort);
        assert!(next_action(Some(&state)).to_string().contains("guard-stop"));

        state.phase = RunnerPhase::Suspended;
        assert_eq!(next_action(Some(&state)), RunnerNextAction::ResumeRun);
        assert!(next_action(Some(&state)).to_string().contains("suspended"));
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
        assert_eq!(
            next_action(Some(&state)),
            RunnerNextAction::FinishSuiteRepair
        );
        assert!(
            next_action(Some(&state))
                .to_string()
                .contains("suite repair")
        );
    }

    #[test]
    fn runner_state_path_builds_correctly() {
        let path = runner_state_path(Path::new("/runs/r1"));
        assert_eq!(path, PathBuf::from("/runs/r1/suite-run-state.json"));
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

    // --- apply_event tests ---

    #[test]
    fn apply_event_cluster_prepared_advances_to_preflight() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        let state = apply_event(dir.path(), "cluster-prepared", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Preflight);
        assert_eq!(state.transition_count, 1);
        assert_eq!(state.last_event.as_deref(), Some("ClusterPrepared"));
    }

    #[test]
    fn apply_event_full_happy_path() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();

        let state = apply_event(dir.path(), "cluster-prepared", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Preflight);

        let state = apply_event(dir.path(), "preflight-started", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Preflight);
        assert_eq!(state.preflight.status, PreflightStatus::Running);

        let state = apply_event(dir.path(), "preflight-captured", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Execution);
        assert_eq!(state.preflight.status, PreflightStatus::Complete);

        let state = apply_event(dir.path(), "closeout-started", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Closeout);

        let state = apply_event(dir.path(), "run-completed", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Completed);
        assert_eq!(state.transition_count, 5);
    }

    #[test]
    fn apply_event_abort_from_execution() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        apply_event(dir.path(), "cluster-prepared", None, None).unwrap();
        apply_event(dir.path(), "preflight-captured", None, None).unwrap();

        let state = apply_event(dir.path(), "abort", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Aborted);
    }

    #[test]
    fn apply_event_suspend_and_resume() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        apply_event(dir.path(), "cluster-prepared", None, None).unwrap();
        apply_event(dir.path(), "preflight-captured", None, None).unwrap();

        let state = apply_event(dir.path(), "suspend", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Suspended);

        let state = apply_event(dir.path(), "resume-run", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Execution);
    }

    #[test]
    fn apply_event_resume_from_aborted() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        apply_event(dir.path(), "abort", None, None).unwrap();

        let state = apply_event(dir.path(), "resume-run", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Execution);
    }

    #[test]
    fn apply_event_invalid_transition_rejected() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();

        // Cannot go to closeout from bootstrap.
        let result = apply_event(dir.path(), "closeout-started", None, None);
        assert!(result.is_err());
        let error = result.unwrap_err();
        assert_eq!(error.code(), "KSRCLI084");
    }

    #[test]
    fn apply_event_unknown_event_rejected() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();

        let result = apply_event(dir.path(), "made-up-event", None, None);
        assert!(result.is_err());
        assert!(result.unwrap_err().message().contains("unknown event"));
    }

    #[test]
    fn apply_event_failure_manifest_sets_triage() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();

        let state = apply_event(
            dir.path(),
            "failure-manifest",
            Some("groups/g1.md"),
            Some("parse error"),
        )
        .unwrap();
        assert_eq!(state.phase, RunnerPhase::Triage);
        assert!(state.failure.is_some());
        let failure = state.failure.unwrap();
        assert_eq!(failure.kind, FailureKind::Manifest);
        assert_eq!(failure.suite_target.as_deref(), Some("groups/g1.md"));
        assert_eq!(failure.message.as_deref(), Some("parse error"));
    }

    #[test]
    fn apply_event_manifest_fix_suite_and_run_sets_suite_fix() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        apply_event(dir.path(), "failure-manifest", Some("groups/g1.md"), None).unwrap();

        let state = apply_event(
            dir.path(),
            "manifest-fix-suite-and-run",
            Some("groups/g1.md"),
            None,
        )
        .unwrap();
        assert_eq!(state.phase, RunnerPhase::Triage);
        let fix = state.suite_fix.unwrap();
        assert_eq!(fix.decision, ManifestFixDecision::SuiteAndRun);
        assert_eq!(fix.approved_paths, vec!["groups/g1.md"]);
        assert!(!fix.suite_written);
        assert!(!fix.amendments_written);
    }

    #[test]
    fn apply_event_manifest_fix_stop_run_aborts() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        apply_event(dir.path(), "failure-manifest", None, None).unwrap();

        let state = apply_event(dir.path(), "manifest-fix-stop-run", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Aborted);
    }

    #[test]
    fn apply_event_suite_fix_resumed_returns_to_execution() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        apply_event(dir.path(), "failure-manifest", None, None).unwrap();
        apply_event(dir.path(), "manifest-fix-run-only", None, None).unwrap();

        let state = apply_event(dir.path(), "suite-fix-resumed", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Execution);
        // suite_fix should be cleared when leaving triage.
        assert!(state.suite_fix.is_none());
    }

    #[test]
    fn apply_event_cannot_transition_from_completed() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        apply_event(dir.path(), "cluster-prepared", None, None).unwrap();
        apply_event(dir.path(), "preflight-captured", None, None).unwrap();
        apply_event(dir.path(), "closeout-started", None, None).unwrap();
        apply_event(dir.path(), "run-completed", None, None).unwrap();

        // Even abort should be rejected from completed.
        let result = apply_event(dir.path(), "abort", None, None);
        assert!(result.is_err());
    }

    // --- ensure_execution_phase tests ---

    #[test]
    fn ensure_execution_phase_from_bootstrap() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();

        let advanced = ensure_execution_phase(dir.path()).unwrap();
        assert!(advanced);

        let state = read_runner_state(dir.path()).unwrap().unwrap();
        assert_eq!(state.phase, RunnerPhase::Execution);
        assert_eq!(state.last_event.as_deref(), Some("AutoAdvanceToExecution"));
    }

    #[test]
    fn ensure_execution_phase_from_preflight() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        apply_event(dir.path(), "cluster-prepared", None, None).unwrap();

        let advanced = ensure_execution_phase(dir.path()).unwrap();
        assert!(advanced);

        let state = read_runner_state(dir.path()).unwrap().unwrap();
        assert_eq!(state.phase, RunnerPhase::Execution);
    }

    #[test]
    fn ensure_execution_phase_noop_when_already_executing() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        apply_event(dir.path(), "cluster-prepared", None, None).unwrap();
        apply_event(dir.path(), "preflight-captured", None, None).unwrap();

        let advanced = ensure_execution_phase(dir.path()).unwrap();
        assert!(!advanced);

        let state = read_runner_state(dir.path()).unwrap().unwrap();
        assert_eq!(state.phase, RunnerPhase::Execution);
    }

    #[test]
    fn ensure_execution_phase_noop_when_no_state() {
        let dir = TempDir::new().unwrap();
        let advanced = ensure_execution_phase(dir.path()).unwrap();
        assert!(!advanced);
    }

    // --- event_label tests ---

    #[test]
    fn event_label_camel_cases_dashed_name() {
        assert_eq!(event_label("cluster-prepared"), "ClusterPrepared");
        assert_eq!(event_label("preflight-started"), "PreflightStarted");
        assert_eq!(event_label("abort"), "Abort");
        assert_eq!(
            event_label("manifest-fix-suite-and-run"),
            "ManifestFixSuiteAndRun"
        );
    }

    // --- is_valid_transition tests ---

    #[test]
    fn valid_transitions_from_bootstrap() {
        assert!(is_valid_transition(
            RunnerPhase::Bootstrap,
            RunnerPhase::Preflight,
            "cluster-prepared"
        ));
        assert!(is_valid_transition(
            RunnerPhase::Bootstrap,
            RunnerPhase::Execution,
            "preflight-captured"
        ));
        assert!(is_valid_transition(
            RunnerPhase::Bootstrap,
            RunnerPhase::Aborted,
            "abort"
        ));
        assert!(!is_valid_transition(
            RunnerPhase::Bootstrap,
            RunnerPhase::Closeout,
            "closeout-started"
        ));
    }

    #[test]
    fn valid_transitions_from_execution() {
        assert!(is_valid_transition(
            RunnerPhase::Execution,
            RunnerPhase::Closeout,
            "closeout-started"
        ));
        assert!(is_valid_transition(
            RunnerPhase::Execution,
            RunnerPhase::Triage,
            "failure-manifest"
        ));
        assert!(is_valid_transition(
            RunnerPhase::Execution,
            RunnerPhase::Suspended,
            "suspend"
        ));
        assert!(!is_valid_transition(
            RunnerPhase::Execution,
            RunnerPhase::Preflight,
            "preflight-started"
        ));
    }

    #[test]
    fn resume_only_from_suspended_or_aborted() {
        assert!(is_valid_transition(
            RunnerPhase::Suspended,
            RunnerPhase::Execution,
            "resume-run"
        ));
        assert!(is_valid_transition(
            RunnerPhase::Aborted,
            RunnerPhase::Execution,
            "resume-run"
        ));
        assert!(!is_valid_transition(
            RunnerPhase::Execution,
            RunnerPhase::Execution,
            "resume-run"
        ));
    }
}
