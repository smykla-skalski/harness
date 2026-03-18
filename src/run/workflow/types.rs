use std::fmt;
use std::path::Path;

use clap::ValueEnum;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

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

/// Maximum number of transition records kept in history.
/// When full, the oldest entry is dropped.
const MAX_HISTORY_ENTRIES: usize = 50;

/// A single recorded phase transition.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TransitionRecord {
    pub from: RunnerPhase,
    pub to: RunnerPhase,
    pub event: String,
    pub timestamp: String,
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
#[serde(deny_unknown_fields)]
pub(super) struct RunnerWorkflowPayload {
    pub phase: RunnerPhase,
    pub preflight: PreflightState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure: Option<FailureState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_fix: Option<SuiteFixState>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub history: Vec<TransitionRecord>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct RunnerWorkflowStateRecord {
    pub state: RunnerWorkflowPayload,
    pub updated_at: String,
    pub transition_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_event: Option<String>,
}

/// Full runner workflow state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunnerWorkflowState {
    pub phase: RunnerPhase,
    pub preflight: PreflightState,
    pub failure: Option<FailureState>,
    pub suite_fix: Option<SuiteFixState>,
    pub updated_at: String,
    pub transition_count: u32,
    pub last_event: Option<String>,
    pub history: Vec<TransitionRecord>,
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

    pub(super) fn touch(&mut self, label: &str) {
        self.transition_count += 1;
        self.updated_at = super::now_utc();
        self.last_event = Some(label.to_string());
    }

    pub(super) fn append_history(&mut self, from: RunnerPhase, to: RunnerPhase, event: &str) {
        if self.history.len() >= MAX_HISTORY_ENTRIES {
            self.history.remove(0);
        }
        self.history.push(TransitionRecord {
            from,
            to,
            event: event.to_string(),
            timestamp: self.updated_at.clone(),
        });
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

    pub(super) fn to_record(&self) -> RunnerWorkflowStateRecord {
        RunnerWorkflowStateRecord {
            state: RunnerWorkflowPayload {
                phase: self.phase,
                preflight: self.preflight.clone(),
                failure: self.failure.clone(),
                suite_fix: self.suite_fix.clone(),
                history: self.history.clone(),
            },
            updated_at: self.updated_at.clone(),
            transition_count: self.transition_count,
            last_event: self.last_event.clone(),
        }
    }

    pub(super) fn from_record(record: RunnerWorkflowStateRecord) -> Self {
        Self {
            phase: record.state.phase,
            preflight: record.state.preflight,
            failure: record.state.failure,
            suite_fix: record.state.suite_fix,
            history: record.state.history,
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
                "Resume the run by executing `harness run preflight` before starting group execution."
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
                "Run is suspended. Resume with `harness run runner-state --event resume-run` \
                 and continue from the saved `next_planned_group`."
            }
            Self::HandleAbort => {
                "Do not blame the user for `guard-stop` feedback. If the stop was unexpected, \
                 run `harness run runner-state --event resume-run`, do not edit `run-status.json` \
                 or `run-report.md`, and continue from the saved `next_planned_group`. \
                 If the run was intentionally halted, keep the aborted report as-is."
            }
        })
    }
}
