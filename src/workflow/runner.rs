use std::fmt;
use std::path::{Path, PathBuf};

use clap::ValueEnum;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::audit_log::append_runner_state_audit;
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

/// Typed runner workflow events.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, ValueEnum)]
#[non_exhaustive]
pub enum RunnerEvent {
    #[value(name = "cluster-prepared")]
    ClusterPrepared,
    #[value(name = "preflight-started")]
    PreflightStarted,
    #[value(name = "preflight-captured")]
    PreflightCaptured,
    #[value(name = "preflight-failed")]
    PreflightFailed,
    #[value(name = "failure-manifest")]
    FailureManifest,
    #[value(name = "manifest-fix-run-only")]
    ManifestFixRunOnly,
    #[value(name = "manifest-fix-suite-and-run")]
    ManifestFixSuiteAndRun,
    #[value(name = "manifest-fix-skip-step")]
    ManifestFixSkipStep,
    #[value(name = "manifest-fix-stop-run")]
    ManifestFixStopRun,
    #[value(name = "suite-fix-resumed")]
    SuiteFixResumed,
    #[value(name = "abort")]
    Abort,
    #[value(name = "suspend")]
    Suspend,
    #[value(name = "resume-run")]
    ResumeRun,
    #[value(name = "closeout-started")]
    CloseoutStarted,
    #[value(name = "run-completed")]
    RunCompleted,
}

impl RunnerEvent {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ClusterPrepared => "cluster-prepared",
            Self::PreflightStarted => "preflight-started",
            Self::PreflightCaptured => "preflight-captured",
            Self::PreflightFailed => "preflight-failed",
            Self::FailureManifest => "failure-manifest",
            Self::ManifestFixRunOnly => "manifest-fix-run-only",
            Self::ManifestFixSuiteAndRun => "manifest-fix-suite-and-run",
            Self::ManifestFixSkipStep => "manifest-fix-skip-step",
            Self::ManifestFixStopRun => "manifest-fix-stop-run",
            Self::SuiteFixResumed => "suite-fix-resumed",
            Self::Abort => "abort",
            Self::Suspend => "suspend",
            Self::ResumeRun => "resume-run",
            Self::CloseoutStarted => "closeout-started",
            Self::RunCompleted => "run-completed",
        }
    }

    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::ClusterPrepared => "ClusterPrepared",
            Self::PreflightStarted => "PreflightStarted",
            Self::PreflightCaptured => "PreflightCaptured",
            Self::PreflightFailed => "PreflightFailed",
            Self::FailureManifest => "FailureManifest",
            Self::ManifestFixRunOnly => "ManifestFixRunOnly",
            Self::ManifestFixSuiteAndRun => "ManifestFixSuiteAndRun",
            Self::ManifestFixSkipStep => "ManifestFixSkipStep",
            Self::ManifestFixStopRun => "ManifestFixStopRun",
            Self::SuiteFixResumed => "SuiteFixResumed",
            Self::Abort => "Abort",
            Self::Suspend => "Suspend",
            Self::ResumeRun => "ResumeRun",
            Self::CloseoutStarted => "CloseoutStarted",
            Self::RunCompleted => "RunCompleted",
        }
    }

    #[must_use]
    pub const fn target_phase(self) -> RunnerPhase {
        match self {
            Self::ClusterPrepared | Self::PreflightStarted => RunnerPhase::Preflight,
            Self::PreflightCaptured | Self::SuiteFixResumed | Self::ResumeRun => {
                RunnerPhase::Execution
            }
            Self::PreflightFailed
            | Self::FailureManifest
            | Self::ManifestFixRunOnly
            | Self::ManifestFixSuiteAndRun
            | Self::ManifestFixSkipStep => RunnerPhase::Triage,
            Self::ManifestFixStopRun | Self::Abort => RunnerPhase::Aborted,
            Self::Suspend => RunnerPhase::Suspended,
            Self::CloseoutStarted => RunnerPhase::Closeout,
            Self::RunCompleted => RunnerPhase::Completed,
        }
    }

    #[must_use]
    pub const fn manifest_fix_decision(self) -> Option<ManifestFixDecision> {
        match self {
            Self::ManifestFixRunOnly => Some(ManifestFixDecision::RunOnly),
            Self::ManifestFixSuiteAndRun => Some(ManifestFixDecision::SuiteAndRun),
            Self::ManifestFixSkipStep => Some(ManifestFixDecision::SkipStep),
            Self::ManifestFixStopRun => Some(ManifestFixDecision::StopRun),
            _ => None,
        }
    }
}

impl fmt::Display for RunnerEvent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl TryFrom<&str> for RunnerEvent {
    type Error = String;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "cluster-prepared" => Ok(Self::ClusterPrepared),
            "preflight-started" => Ok(Self::PreflightStarted),
            "preflight-captured" => Ok(Self::PreflightCaptured),
            "preflight-failed" => Ok(Self::PreflightFailed),
            "failure-manifest" => Ok(Self::FailureManifest),
            "manifest-fix-run-only" => Ok(Self::ManifestFixRunOnly),
            "manifest-fix-suite-and-run" => Ok(Self::ManifestFixSuiteAndRun),
            "manifest-fix-skip-step" => Ok(Self::ManifestFixSkipStep),
            "manifest-fix-stop-run" => Ok(Self::ManifestFixStopRun),
            "suite-fix-resumed" => Ok(Self::SuiteFixResumed),
            "abort" => Ok(Self::Abort),
            "suspend" => Ok(Self::Suspend),
            "resume-run" => Ok(Self::ResumeRun),
            "closeout-started" => Ok(Self::CloseoutStarted),
            "run-completed" => Ok(Self::RunCompleted),
            other => Err(other.to_string()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct RunnerWorkflowPayload {
    pub phase: RunnerPhase,
    pub preflight: PreflightState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure: Option<FailureState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_fix: Option<SuiteFixState>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct RunnerWorkflowStateRecord {
    pub schema_version: u32,
    pub state: RunnerWorkflowPayload,
    pub updated_at: String,
    pub transition_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_event: Option<String>,
}

/// Full runner workflow state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunnerWorkflowState {
    pub schema_version: u32,
    pub phase: RunnerPhase,
    pub preflight: PreflightState,
    pub failure: Option<FailureState>,
    pub suite_fix: Option<SuiteFixState>,
    pub updated_at: String,
    pub transition_count: u32,
    pub last_event: Option<String>,
}

impl RunnerWorkflowState {
    #[must_use]
    pub fn phase(&self) -> RunnerPhase {
        self.phase
    }

    #[must_use]
    pub fn preflight_status(&self) -> PreflightStatus {
        self.preflight.status
    }

    #[must_use]
    pub fn failure(&self) -> Option<&FailureState> {
        self.failure.as_ref()
    }

    #[must_use]
    pub fn suite_fix(&self) -> Option<&SuiteFixState> {
        self.suite_fix.as_ref()
    }

    fn touch(&mut self, label: &str) {
        self.transition_count += 1;
        self.updated_at = now_utc();
        self.last_event = Some(label.to_string());
    }

    #[must_use]
    pub fn request_failure_triage(
        &self,
        kind: FailureKind,
        suite_target: Option<&str>,
        message: Option<&str>,
        event_label: &str,
    ) -> Self {
        let mut next = self.clone();
        next.phase = RunnerPhase::Triage;
        next.failure = Some(FailureState {
            kind,
            suite_target: suite_target.map(str::to_string),
            message: message.map(str::to_string),
        });
        next.suite_fix = None;
        next.touch(event_label);
        next
    }

    #[must_use]
    pub fn request_preflight_failed(&self, event_label: &str) -> Self {
        let mut next = self.clone();
        next.preflight.status = PreflightStatus::Pending;
        next.touch(event_label);
        next
    }

    #[must_use]
    pub fn record_preflight_captured(&self, event_label: &str) -> Self {
        let mut next = self.clone();
        next.phase = RunnerPhase::Execution;
        next.preflight.status = PreflightStatus::Complete;
        next.failure = None;
        next.suite_fix = None;
        next.touch(event_label);
        next
    }

    #[must_use]
    pub fn record_suite_fix_write(&self, path: &Path, suite_dir: &Path) -> Option<Self> {
        let mut next = self.clone();
        let suite_fix = next.suite_fix.as_mut()?;
        if !path.starts_with(suite_dir) {
            return None;
        }

        let mut changed = false;
        let amendments_path = suite_dir.join("amendments.md");
        let suite_manifest = suite_dir.join("suite.md");
        let groups_dir = suite_dir.join("groups");
        let baseline_dir = suite_dir.join("baseline");

        if path == amendments_path {
            changed = !suite_fix.amendments_written;
            suite_fix.amendments_written = true;
        } else if path == suite_manifest
            || path.starts_with(groups_dir)
            || path.starts_with(baseline_dir)
        {
            changed = !suite_fix.suite_written;
            suite_fix.suite_written = true;
        }

        if !changed {
            return None;
        }

        next.touch("SuiteFixWriteTracked");
        Some(next)
    }

    fn to_record(&self) -> RunnerWorkflowStateRecord {
        RunnerWorkflowStateRecord {
            schema_version: self.schema_version,
            state: RunnerWorkflowPayload {
                phase: self.phase,
                preflight: self.preflight.clone(),
                failure: self.failure.clone(),
                suite_fix: self.suite_fix.clone(),
            },
            updated_at: self.updated_at.clone(),
            transition_count: self.transition_count,
            last_event: self.last_event.clone(),
        }
    }

    fn from_record(record: RunnerWorkflowStateRecord) -> Self {
        Self {
            schema_version: record.schema_version,
            phase: record.state.phase,
            preflight: record.state.preflight,
            failure: record.state.failure,
            suite_fix: record.state.suite_fix,
            updated_at: record.updated_at,
            transition_count: record.transition_count,
            last_event: record.last_event,
        }
    }
}

impl Serialize for RunnerWorkflowState {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        self.to_record().serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for RunnerWorkflowState {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        RunnerWorkflowStateRecord::deserialize(deserializer).map(Self::from_record)
    }
}

const RUNNER_STATE_SCHEMA_VERSION: u32 = 2;

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
    append_runner_state_audit(run_dir, state)?;
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
    let mut state = read_runner_state(run_dir)?.unwrap_or_else(|| make_initial_state(&now_utc()));

    let new_phase = resolve_transition(&state, event)?;
    state.phase = new_phase;
    state.touch(event.label());

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
        RunnerEvent::PreflightStarted => state.preflight.status = PreflightStatus::Running,
        RunnerEvent::PreflightCaptured => state.preflight.status = PreflightStatus::Complete,
        _ => {}
    }

    // Set failure on failure-manifest.
    if event == RunnerEvent::FailureManifest {
        state.failure = Some(FailureState {
            kind: FailureKind::Manifest,
            suite_target: suite_target.map(str::to_string),
            message: message.map(str::to_string),
        });
    }

    // Set suite_fix on manifest-fix decisions that enter triage.
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
        state.touch("AutoAdvanceToExecution");
        save_state(run_dir, &state)?;
        return Ok(true);
    }
    Ok(false)
}

/// Map an event name to the target phase, validating that the transition
/// is legal from the current phase.
fn resolve_transition(
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
fn is_valid_transition<E>(from: RunnerPhase, to: RunnerPhase, event: E) -> bool
where
    E: TryInto<RunnerEvent>,
{
    let Ok(event) = event.try_into() else {
        return false;
    };
    // Abort and suspend are allowed from any non-terminal phase.
    if matches!(to, RunnerPhase::Aborted | RunnerPhase::Suspended) {
        return !matches!(from, RunnerPhase::Completed);
    }
    // Resume is only valid from suspended or aborted.
    if event == RunnerEvent::ResumeRun {
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
#[cfg(test)]
fn event_label(event: &str) -> String {
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
        assert_eq!(json["state"]["phase"], "bootstrap");
        assert_eq!(json["state"]["preflight"]["status"], "pending");
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
