use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};
use crate::run::args::RunDirArgs;
use crate::run::context::{RunLayout, RunMetadata};
use crate::run::workflow::{read_runner_state, RunnerPhase, RunnerWorkflowState, TransitionRecord};
use crate::run::{RunCounts, RunStatus};
use crate::workspace::utc_now;

use super::types::RunDiagnosticCheck;

pub(super) fn explicit_run_dir(args: &RunDirArgs) -> Result<Option<PathBuf>, CliError> {
    if let Some(run_dir) = args.run_dir.as_ref() {
        return Ok(Some(run_dir.clone()));
    }
    if let (Some(run_root), Some(run_id)) = (args.run_root.as_ref(), args.run_id.as_deref()) {
        return Ok(Some(run_root.join(run_id)));
    }
    if let Some(run_id) = args.run_id.as_deref() {
        return Err(CliErrorKind::missing_run_location(run_id.to_string()).into());
    }
    Ok(None)
}

pub(super) fn repaired_status(metadata: &RunMetadata, status: &RunStatus) -> Option<RunStatus> {
    let mut repaired = status.clone();
    repaired.run_id.clone_from(&metadata.run_id);
    repaired.suite_id.clone_from(&metadata.suite_id);
    repaired.profile.clone_from(&metadata.profile);
    repaired.counts = derived_counts(status);
    repaired.last_completed_group = status
        .executed_groups
        .last()
        .map(|group| group.group_id.clone());
    repaired.last_state_capture = status.last_group_capture_value().map(str::to_string);
    repaired.last_updated_utc = derived_last_updated(status);

    if &repaired == status {
        None
    } else {
        Some(repaired)
    }
}

pub(super) fn repaired_workflow(run_dir: &Path) -> Result<Option<RunnerWorkflowState>, CliError> {
    let Some(mut workflow) = read_runner_state(run_dir)? else {
        return Ok(None);
    };
    let layout = RunLayout::from_run_dir(run_dir);
    let status = RunStatus::load(&layout.status_path())?;
    let report_exists = layout.report_path().exists();

    if status.overall_verdict.is_finalized() && report_exists {
        let needs_phase = workflow.phase != RunnerPhase::Completed;
        let needs_triage_clear = workflow.failure.is_some() || workflow.suite_fix.is_some();
        if needs_phase || needs_triage_clear {
            let previous = workflow.phase;
            workflow.phase = RunnerPhase::Completed;
            workflow.failure = None;
            workflow.suite_fix = None;
            workflow.transition_count += 1;
            workflow.updated_at = utc_now();
            workflow.last_event = Some("RunRepairCompleted".to_string());
            workflow.history.push(TransitionRecord {
                from: previous,
                to: RunnerPhase::Completed,
                event: "RunRepairCompleted".to_string(),
                timestamp: workflow.updated_at.clone(),
            });
            return Ok(Some(workflow));
        }
    }

    Ok(None)
}

pub(super) fn derived_counts(status: &RunStatus) -> RunCounts {
    let mut counts = RunCounts::default();
    for group in &status.executed_groups {
        counts.increment(group.verdict);
    }
    counts
}

pub(super) fn derived_last_updated(status: &RunStatus) -> Option<String> {
    status
        .completed_at
        .clone()
        .or_else(|| {
            status
                .executed_groups
                .last()
                .map(|group| group.completed_at.clone())
        })
        .or_else(|| Some(status.started_at.clone()))
}

pub(super) fn ok_check(
    code: &'static str,
    kind: &'static str,
    summary: impl Into<String>,
    path: Option<&Path>,
) -> RunDiagnosticCheck {
    RunDiagnosticCheck {
        code,
        kind,
        status: "ok",
        summary: summary.into(),
        path: path.map(|value| value.display().to_string()),
        repairable: false,
        hint: None,
    }
}

pub(super) fn error_check(
    code: &'static str,
    kind: &'static str,
    summary: impl Into<String>,
    path: Option<&Path>,
    repairable: bool,
    hint: Option<&str>,
) -> RunDiagnosticCheck {
    RunDiagnosticCheck {
        code,
        kind,
        status: "error",
        summary: summary.into(),
        path: path.map(|value| value.display().to_string()),
        repairable,
        hint: hint.map(str::to_string),
    }
}

pub(super) fn fixed_check(
    code: &'static str,
    kind: &'static str,
    summary: impl Into<String>,
    path: Option<&Path>,
) -> RunDiagnosticCheck {
    RunDiagnosticCheck {
        code,
        kind,
        status: "fixed",
        summary: summary.into(),
        path: path.map(|value| value.display().to_string()),
        repairable: false,
        hint: None,
    }
}
