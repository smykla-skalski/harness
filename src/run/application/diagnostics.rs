use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_json_typed;
use crate::kernel::topology::ClusterSpec;
use crate::run::args::RunDirArgs;
use crate::run::audit::write_run_status_with_audit;
use crate::run::context::{CurrentRunPointer, RunLayout, RunMetadata, RunRepository};
use crate::run::workflow::{
    PreflightStatus, RunnerPhase, RunnerWorkflowState, TransitionRecord, read_runner_state,
    runner_state_path, write_runner_state,
};
use crate::run::{RunCounts, RunStatus};
use crate::workspace::{current_run_context_path, utc_now};

#[derive(Debug, Clone, Serialize)]
pub struct RunDiagnosticTarget {
    pub run_dir: String,
    pub current_run_pointer: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct RunDiagnosticCheck {
    pub code: &'static str,
    pub kind: &'static str,
    pub status: &'static str,
    pub summary: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    pub repairable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct RunDiagnosticReport {
    pub ok: bool,
    pub command: &'static str,
    pub target: RunDiagnosticTarget,
    pub checks: Vec<RunDiagnosticCheck>,
    pub repairs_applied: Vec<RunDiagnosticCheck>,
    pub remaining_findings: Vec<RunDiagnosticCheck>,
}

#[derive(Debug, Clone)]
enum PointerState {
    Missing,
    Invalid(String),
    Present(Box<CurrentRunPointer>),
}

#[derive(Debug, Clone)]
struct ResolvedRunTarget {
    explicit: bool,
    requested_run_dir: Option<PathBuf>,
    pointer_path: PathBuf,
    pointer_state: PointerState,
}

impl ResolvedRunTarget {
    fn resolve(args: &RunDirArgs) -> Result<Self, CliError> {
        let explicit_run_dir = explicit_run_dir(args)?;
        let pointer_path = current_run_context_path()?;
        let pointer_state = if pointer_path.exists() {
            match read_json_typed::<CurrentRunPointer>(&pointer_path) {
                Ok(pointer) => PointerState::Present(Box::new(pointer)),
                Err(error) => PointerState::Invalid(error.to_string()),
            }
        } else {
            PointerState::Missing
        };
        let requested_run_dir = explicit_run_dir.clone().or_else(|| match &pointer_state {
            PointerState::Present(pointer) => Some(pointer.layout.run_dir()),
            PointerState::Missing | PointerState::Invalid(_) => None,
        });

        Ok(Self {
            explicit: explicit_run_dir.is_some(),
            requested_run_dir,
            pointer_path,
            pointer_state,
        })
    }

    fn target_label(&self) -> String {
        self.requested_run_dir.as_ref().map_or_else(
            || "current-session".to_string(),
            |path| path.display().to_string(),
        )
    }
}

pub fn doctor(args: &RunDirArgs) -> Result<RunDiagnosticReport, CliError> {
    let target = ResolvedRunTarget::resolve(args)?;
    Ok(build_report(&target, "run doctor", vec![], false))
}

pub fn repair(args: &RunDirArgs) -> Result<RunDiagnosticReport, CliError> {
    let target = ResolvedRunTarget::resolve(args)?;
    let mut repairs_applied = vec![];
    let repo = RunRepository;
    let allow_missing_pointer = clear_stale_pointer_if_needed(&target, repo, &mut repairs_applied)?;
    repair_target_run_if_needed(&target, repo, &mut repairs_applied)?;

    let refreshed_target = ResolvedRunTarget::resolve(args)?;
    Ok(build_report(
        &refreshed_target,
        "run repair",
        repairs_applied,
        allow_missing_pointer,
    ))
}

fn build_report(
    target: &ResolvedRunTarget,
    command: &'static str,
    repairs_applied: Vec<RunDiagnosticCheck>,
    allow_missing_pointer: bool,
) -> RunDiagnosticReport {
    let mut checks = vec![];
    append_pointer_checks(target, &mut checks, allow_missing_pointer);

    if let Some(run_dir) = target.requested_run_dir.as_deref() {
        append_run_checks(run_dir, target, &mut checks);
    }

    let remaining_findings: Vec<RunDiagnosticCheck> = checks
        .iter()
        .filter(|check| check.status != "ok")
        .cloned()
        .collect();

    RunDiagnosticReport {
        ok: remaining_findings.is_empty(),
        command,
        target: RunDiagnosticTarget {
            run_dir: target.target_label(),
            current_run_pointer: target.pointer_path.display().to_string(),
        },
        checks,
        repairs_applied,
        remaining_findings,
    }
}

fn clear_stale_pointer_if_needed(
    target: &ResolvedRunTarget,
    repo: RunRepository,
    repairs_applied: &mut Vec<RunDiagnosticCheck>,
) -> Result<bool, CliError> {
    let stale_pointer = !target.explicit
        && matches!(
            &target.pointer_state,
            PointerState::Present(pointer) if !pointer.layout.run_dir().is_dir()
        );
    if !stale_pointer {
        return Ok(false);
    }

    repo.clear_current_pointer()?;
    repairs_applied.push(fixed_check(
        "run_pointer_cleared",
        "pointer",
        "Cleared the stale current run pointer for the active session.",
        Some(&target.pointer_path),
    ));
    Ok(true)
}

fn repair_target_run_if_needed(
    target: &ResolvedRunTarget,
    repo: RunRepository,
    repairs_applied: &mut Vec<RunDiagnosticCheck>,
) -> Result<(), CliError> {
    let Some(run_dir) = target.requested_run_dir.as_deref() else {
        return Ok(());
    };
    if !run_dir.is_dir() {
        return Ok(());
    }

    let layout = RunLayout::from_run_dir(run_dir);
    let metadata = load_required_metadata(&layout).ok();
    let status = load_required_status(&layout).ok();
    let cluster = load_cluster_spec(&layout).ok().flatten();

    rebuild_pointer_if_needed(
        target,
        repo,
        run_dir,
        &layout,
        metadata.as_ref(),
        cluster,
        repairs_applied,
    )?;
    rewrite_status_if_needed(
        run_dir,
        &layout,
        metadata.as_ref(),
        status.as_ref(),
        repairs_applied,
    )?;
    rewrite_workflow_if_needed(run_dir, repairs_applied)?;

    Ok(())
}

fn rebuild_pointer_if_needed(
    target: &ResolvedRunTarget,
    repo: RunRepository,
    run_dir: &Path,
    layout: &RunLayout,
    metadata: Option<&RunMetadata>,
    cluster: Option<ClusterSpec>,
    repairs_applied: &mut Vec<RunDiagnosticCheck>,
) -> Result<(), CliError> {
    if !target.explicit {
        return Ok(());
    }
    let Some(metadata) = metadata else {
        return Ok(());
    };

    let pointer = CurrentRunPointer::from_metadata(layout.clone(), metadata, cluster);
    repo.save_current_pointer(&pointer)?;
    repairs_applied.push(fixed_check(
        "run_pointer_rebuilt",
        "pointer",
        format!(
            "Rebuilt the current run pointer from {}.",
            run_dir.display()
        ),
        Some(&target.pointer_path),
    ));
    Ok(())
}

fn rewrite_status_if_needed(
    run_dir: &Path,
    layout: &RunLayout,
    metadata: Option<&RunMetadata>,
    status: Option<&RunStatus>,
    repairs_applied: &mut Vec<RunDiagnosticCheck>,
) -> Result<(), CliError> {
    let (Some(metadata), Some(status)) = (metadata, status) else {
        return Ok(());
    };
    let Some(next_status) = repaired_status(metadata, status) else {
        return Ok(());
    };

    write_run_status_with_audit(run_dir, &next_status, None, Some("repair"), None)?;
    repairs_applied.push(fixed_check(
        "run_status_rewritten",
        "status",
        "Rewrote deterministic run status fields from persisted run data.",
        Some(&layout.status_path()),
    ));
    Ok(())
}

fn rewrite_workflow_if_needed(
    run_dir: &Path,
    repairs_applied: &mut Vec<RunDiagnosticCheck>,
) -> Result<(), CliError> {
    let Some(next_state) = repaired_workflow(run_dir)? else {
        return Ok(());
    };

    write_runner_state(run_dir, &next_state)?;
    repairs_applied.push(fixed_check(
        "run_workflow_completed",
        "workflow",
        "Synchronized the runner workflow to a completed state from persisted report evidence.",
        Some(&runner_state_path(run_dir)),
    ));
    Ok(())
}

fn append_pointer_checks(
    target: &ResolvedRunTarget,
    checks: &mut Vec<RunDiagnosticCheck>,
    allow_missing_pointer: bool,
) {
    match &target.pointer_state {
        PointerState::Missing => {
            if target.explicit {
                checks.push(ok_check(
                    "run_pointer_absent",
                    "pointer",
                    "No current run pointer is recorded for this session.",
                    Some(&target.pointer_path),
                ));
            } else if allow_missing_pointer {
                checks.push(ok_check(
                    "run_pointer_cleared",
                    "pointer",
                    "No active run pointer remains after repair.",
                    Some(&target.pointer_path),
                ));
            } else {
                checks.push(error_check(
                    "run_pointer_missing",
                    "pointer",
                    "No current run pointer is recorded. Pass `--run-dir` or `--run-id` to inspect a specific run.",
                    Some(&target.pointer_path),
                    false,
                    Some("Use `harness run doctor --run-dir <path>` to inspect a specific run."),
                ));
            }
        }
        PointerState::Invalid(error) => checks.push(error_check(
            "run_pointer_invalid",
            "pointer",
            format!("Current run pointer is unreadable: {error}"),
            Some(&target.pointer_path),
            true,
            Some("Run `harness run repair` with an explicit run to rebuild the pointer."),
        )),
        PointerState::Present(pointer) => {
            let pointed_run = pointer.layout.run_dir();
            if !pointed_run.is_dir() {
                checks.push(error_check(
                    "run_pointer_stale",
                    "pointer",
                    format!(
                        "Current run pointer targets a missing run directory: {}.",
                        pointed_run.display()
                    ),
                    Some(&target.pointer_path),
                    true,
                    Some("Run `harness run repair` to clear or rebuild the stale pointer."),
                ));
            } else if target.explicit {
                if target
                    .requested_run_dir
                    .as_deref()
                    .is_some_and(|run_dir| run_dir == pointed_run)
                {
                    checks.push(ok_check(
                        "run_pointer_matches",
                        "pointer",
                        "Current run pointer matches the selected run.",
                        Some(&target.pointer_path),
                    ));
                } else {
                    checks.push(error_check(
                        "run_pointer_mismatch",
                        "pointer",
                        format!(
                            "Current run pointer targets {}, not the selected run.",
                            pointed_run.display()
                        ),
                        Some(&target.pointer_path),
                        true,
                        Some("Run `harness run repair --run-dir <path>` to rebuild the pointer."),
                    ));
                }
            } else {
                checks.push(ok_check(
                    "run_pointer_present",
                    "pointer",
                    format!("Current run pointer resolves to {}.", pointed_run.display()),
                    Some(&target.pointer_path),
                ));
            }
        }
    }
}

fn append_run_checks(
    run_dir: &Path,
    target: &ResolvedRunTarget,
    checks: &mut Vec<RunDiagnosticCheck>,
) {
    if !run_dir.is_dir() {
        checks.push(error_check(
            "run_dir_missing",
            "run",
            format!("Run directory is missing: {}.", run_dir.display()),
            Some(run_dir),
            !target.explicit,
            None,
        ));
        return;
    }

    checks.push(ok_check(
        "run_dir_present",
        "run",
        "Run directory exists.",
        Some(run_dir),
    ));

    let layout = RunLayout::from_run_dir(run_dir);
    let metadata = match load_required_metadata(&layout) {
        Ok(metadata) => {
            checks.push(ok_check(
                "run_metadata_present",
                "metadata",
                "Run metadata is readable.",
                Some(&layout.metadata_path()),
            ));
            Some(metadata)
        }
        Err(check) => {
            checks.push(*check);
            None
        }
    };

    let status = match load_required_status(&layout) {
        Ok(status) => {
            checks.push(ok_check(
                "run_status_present",
                "status",
                "Run status is readable.",
                Some(&layout.status_path()),
            ));
            Some(status)
        }
        Err(check) => {
            checks.push(*check);
            None
        }
    };

    let workflow = match load_workflow(&layout) {
        Ok(workflow) => {
            checks.push(ok_check(
                "run_workflow_present",
                "workflow",
                "Runner workflow state is readable.",
                Some(&runner_state_path(run_dir)),
            ));
            Some(workflow)
        }
        Err(check) => {
            checks.push(*check);
            None
        }
    };

    if let (Some(metadata), Some(status)) = (metadata.as_ref(), status.as_ref()) {
        append_status_identity_checks(metadata, status, &layout, checks);
        append_status_derivation_checks(status, &layout, checks);
        append_capture_reference_checks(status, run_dir, checks);
    }

    if let (Some(status), Some(workflow)) = (status.as_ref(), workflow.as_ref()) {
        append_phase_artifact_checks(status, workflow, &layout, checks);
        append_completion_checks(status, workflow, &layout, checks);
    }
}

fn append_status_identity_checks(
    metadata: &RunMetadata,
    status: &RunStatus,
    layout: &RunLayout,
    checks: &mut Vec<RunDiagnosticCheck>,
) {
    if status.run_id != metadata.run_id {
        checks.push(error_check(
            "run_status_run_id_mismatch",
            "status",
            format!(
                "Run status run_id is `{}`, expected `{}`.",
                status.run_id, metadata.run_id
            ),
            Some(&layout.status_path()),
            true,
            None,
        ));
    }
    if status.suite_id != metadata.suite_id {
        checks.push(error_check(
            "run_status_suite_id_mismatch",
            "status",
            format!(
                "Run status suite_id is `{}`, expected `{}`.",
                status.suite_id, metadata.suite_id
            ),
            Some(&layout.status_path()),
            true,
            None,
        ));
    }
    if status.profile != metadata.profile {
        checks.push(error_check(
            "run_status_profile_mismatch",
            "status",
            format!(
                "Run status profile is `{}`, expected `{}`.",
                status.profile, metadata.profile
            ),
            Some(&layout.status_path()),
            true,
            None,
        ));
    }
}

fn append_status_derivation_checks(
    status: &RunStatus,
    layout: &RunLayout,
    checks: &mut Vec<RunDiagnosticCheck>,
) {
    let expected_counts = derived_counts(status);
    if status.counts != expected_counts {
        checks.push(error_check(
            "run_status_counts_mismatch",
            "status",
            format!(
                "Run status counts are {:?}, expected {:?} from executed groups.",
                status.counts, expected_counts
            ),
            Some(&layout.status_path()),
            true,
            None,
        ));
    }

    let expected_last_group = status
        .executed_groups
        .last()
        .map(|group| group.group_id.clone());
    if status.last_completed_group != expected_last_group {
        checks.push(error_check(
            "run_status_last_group_mismatch",
            "status",
            format!(
                "Run status last_completed_group is {:?}, expected {:?}.",
                status.last_completed_group, expected_last_group
            ),
            Some(&layout.status_path()),
            true,
            None,
        ));
    }

    let expected_capture = status.last_group_capture_value().map(str::to_string);
    if status.last_state_capture != expected_capture {
        checks.push(error_check(
            "run_status_last_capture_mismatch",
            "status",
            format!(
                "Run status last_state_capture is {:?}, expected {:?}.",
                status.last_state_capture, expected_capture
            ),
            Some(&layout.status_path()),
            true,
            None,
        ));
    }

    let expected_updated = derived_last_updated(status);
    if status.last_updated_utc != expected_updated {
        checks.push(error_check(
            "run_status_last_updated_mismatch",
            "status",
            format!(
                "Run status last_updated_utc is {:?}, expected {:?}.",
                status.last_updated_utc, expected_updated
            ),
            Some(&layout.status_path()),
            true,
            None,
        ));
    }
}

fn append_capture_reference_checks(
    status: &RunStatus,
    run_dir: &Path,
    checks: &mut Vec<RunDiagnosticCheck>,
) {
    for group in &status.executed_groups {
        let Some(relative_capture) = group.state_capture_at_report.as_deref() else {
            continue;
        };
        let capture_path = run_dir.join(relative_capture);
        if !capture_path.exists() {
            checks.push(error_check(
                "run_state_capture_missing",
                "artifacts",
                format!(
                    "Executed group `{}` references missing state capture `{}`.",
                    group.group_id, relative_capture
                ),
                Some(&capture_path),
                false,
                None,
            ));
        }
    }
}

fn append_phase_artifact_checks(
    status: &RunStatus,
    workflow: &RunnerWorkflowState,
    layout: &RunLayout,
    checks: &mut Vec<RunDiagnosticCheck>,
) {
    let phase = workflow.phase();
    let prepared_suite_required = matches!(
        phase,
        RunnerPhase::Execution
            | RunnerPhase::Triage
            | RunnerPhase::Closeout
            | RunnerPhase::Completed
            | RunnerPhase::Suspended
            | RunnerPhase::Aborted
    );
    if prepared_suite_required && !layout.prepared_suite_path().exists() {
        checks.push(error_check(
            "run_prepared_suite_missing",
            "artifacts",
            "Prepared suite artifact is missing for the current workflow phase.",
            Some(&layout.prepared_suite_path()),
            false,
            None,
        ));
    }

    let preflight_required =
        prepared_suite_required || workflow.preflight_status() == PreflightStatus::Complete;
    if preflight_required && !layout.preflight_artifact_path().exists() {
        checks.push(error_check(
            "run_preflight_artifact_missing",
            "artifacts",
            "Preflight artifact is missing for the current workflow phase.",
            Some(&layout.preflight_artifact_path()),
            false,
            None,
        ));
    }

    let command_log_required = status.overall_verdict.is_finalized()
        || matches!(phase, RunnerPhase::Closeout | RunnerPhase::Completed);
    if command_log_required && !layout.command_log_path().exists() {
        checks.push(error_check(
            "run_command_log_missing",
            "artifacts",
            "Command log is missing for a finalized or closeout run.",
            Some(&layout.command_log_path()),
            false,
            None,
        ));
    }
}

fn append_completion_checks(
    status: &RunStatus,
    workflow: &RunnerWorkflowState,
    layout: &RunLayout,
    checks: &mut Vec<RunDiagnosticCheck>,
) {
    let report_exists = layout.report_path().exists();
    if status.overall_verdict.is_finalized() {
        if !report_exists {
            checks.push(error_check(
                "run_report_missing",
                "report",
                "Run report is missing even though the verdict is final.",
                Some(&layout.report_path()),
                false,
                Some("Recreate the report from tracked artifacts before closing the run."),
            ));
        } else if workflow.phase() != RunnerPhase::Completed {
            checks.push(error_check(
                "run_workflow_not_completed",
                "workflow",
                format!(
                    "Runner workflow phase is `{}`, expected `completed` for a final verdict.",
                    workflow.phase()
                ),
                Some(&runner_state_path(&layout.run_dir())),
                true,
                Some("Run `harness run repair` to synchronize the workflow state."),
            ));
        }
    } else if workflow.phase() == RunnerPhase::Completed {
        checks.push(error_check(
            "run_workflow_completed_without_verdict",
            "workflow",
            "Runner workflow is completed, but run status still has a non-final verdict.",
            Some(&runner_state_path(&layout.run_dir())),
            false,
            None,
        ));
    }
}

fn explicit_run_dir(args: &RunDirArgs) -> Result<Option<PathBuf>, CliError> {
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

fn load_required_metadata(layout: &RunLayout) -> Result<RunMetadata, Box<RunDiagnosticCheck>> {
    let path = layout.metadata_path();
    if !path.exists() {
        return Err(Box::new(error_check(
            "run_metadata_missing",
            "metadata",
            "Run metadata file is missing.",
            Some(&path),
            false,
            None,
        )));
    }
    read_json_typed(&path).map_err(|error| {
        Box::new(error_check(
            "run_metadata_invalid",
            "metadata",
            format!("Run metadata is unreadable: {error}"),
            Some(&path),
            false,
            None,
        ))
    })
}

fn load_required_status(layout: &RunLayout) -> Result<RunStatus, Box<RunDiagnosticCheck>> {
    let path = layout.status_path();
    if !path.exists() {
        return Err(Box::new(error_check(
            "run_status_missing",
            "status",
            "Run status file is missing.",
            Some(&path),
            false,
            None,
        )));
    }
    read_json_typed(&path).map_err(|error| {
        Box::new(error_check(
            "run_status_invalid",
            "status",
            format!("Run status is unreadable: {error}"),
            Some(&path),
            false,
            None,
        ))
    })
}

fn load_workflow(layout: &RunLayout) -> Result<RunnerWorkflowState, Box<RunDiagnosticCheck>> {
    let run_dir = layout.run_dir();
    let path = runner_state_path(&run_dir);
    match read_runner_state(&run_dir) {
        Ok(Some(state)) => Ok(state),
        Ok(None) => Err(Box::new(error_check(
            "run_workflow_missing",
            "workflow",
            "Runner workflow state file is missing.",
            Some(&path),
            false,
            None,
        ))),
        Err(error) => Err(Box::new(error_check(
            "run_workflow_invalid",
            "workflow",
            format!("Runner workflow state is unreadable: {error}"),
            Some(&path),
            false,
            None,
        ))),
    }
}

fn load_cluster_spec(layout: &RunLayout) -> Result<Option<ClusterSpec>, CliError> {
    let path = layout.state_dir().join("cluster.json");
    if !path.exists() {
        return Ok(None);
    }
    read_json_typed(&path).map(Some)
}

fn repaired_status(metadata: &RunMetadata, status: &RunStatus) -> Option<RunStatus> {
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

fn repaired_workflow(run_dir: &Path) -> Result<Option<RunnerWorkflowState>, CliError> {
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

fn derived_counts(status: &RunStatus) -> RunCounts {
    let mut counts = RunCounts::default();
    for group in &status.executed_groups {
        counts.increment(group.verdict);
    }
    counts
}

fn derived_last_updated(status: &RunStatus) -> Option<String> {
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

fn ok_check(
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

fn error_check(
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

fn fixed_check(
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
