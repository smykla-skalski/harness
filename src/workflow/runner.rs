use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::CliError;

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
pub enum PreflightStatus {
    Pending,
    Running,
    Complete,
}

/// Kind of failure in the runner workflow.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureKind {
    Manifest,
    Environment,
    Product,
}

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
    #[serde(default)]
    pub suite_target: Option<String>,
    #[serde(default)]
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
    #[serde(default)]
    pub failure: Option<FailureState>,
    #[serde(default)]
    pub suite_fix: Option<SuiteFixState>,
    pub updated_at: String,
    pub transition_count: u32,
    #[serde(default)]
    pub last_event: Option<String>,
}

/// Path to the runner state file.
#[must_use]
pub fn runner_state_path(run_dir: &Path) -> PathBuf {
    run_dir.join("suite-runner-state.json")
}

/// Initialize runner state for a new run.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn initialize_runner_state(_run_dir: &Path) -> Result<RunnerWorkflowState, CliError> {
    todo!()
}

/// Read runner state from disk.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn read_runner_state(_run_dir: &Path) -> Result<Option<RunnerWorkflowState>, CliError> {
    todo!()
}

/// Write runner state to disk.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn write_runner_state(
    _run_dir: &Path,
    _state: &RunnerWorkflowState,
) -> Result<RunnerWorkflowState, CliError> {
    todo!()
}

/// Get the next action hint based on runner state.
#[must_use]
pub fn next_action(_state: Option<&RunnerWorkflowState>) -> &'static str {
    todo!()
}

#[cfg(test)]
mod tests {}
