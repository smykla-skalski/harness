use std::path::Path;

use crate::errors::CliError;
use crate::kernel::topology::ClusterSpec;
use crate::run::args::RunDirArgs;
use crate::run::audit::write_run_status_with_audit;
use crate::run::context::{CurrentRunPointer, RunLayout, RunMetadata, RunRepository};
use crate::run::workflow::{runner_state_path, write_runner_state};
use crate::run::RunStatus;

use super::checks::{append_pointer_checks, append_run_checks};
use super::helpers::{fixed_check, repaired_status, repaired_workflow};
use super::loading::{load_required_metadata, load_required_status};
use super::types::{
    ResolvedRunTarget, RunDiagnosticCheck, RunDiagnosticReport, RunDiagnosticTarget,
};

pub(crate) fn doctor(args: &RunDirArgs) -> Result<RunDiagnosticReport, CliError> {
    let target = ResolvedRunTarget::resolve(args)?;
    Ok(build_report(&target, "run doctor", vec![], false))
}

pub(crate) fn repair(args: &RunDirArgs) -> Result<RunDiagnosticReport, CliError> {
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
            super::types::PointerState::Present(pointer) if !pointer.layout.run_dir().is_dir()
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
    let cluster = super::loading::load_run_artifacts(&layout, &mut Vec::new()).cluster;

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
