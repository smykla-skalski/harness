use std::collections::BTreeMap;
use std::path::Path;

use crate::kernel::topology::{ClusterProvider, ClusterSpec};
use crate::run::RunStatus;
use crate::run::context::{RunLayout, RunMetadata};
use crate::run::workflow::{PreflightStatus, RunnerPhase, RunnerWorkflowState, runner_state_path};
use crate::workspace::{
    RemoteKubernetesInstallState, load_remote_install_state_for_spec,
    remote_install_state_path_for_spec,
};

use super::helpers::{derived_counts, derived_last_updated, error_check, ok_check};
use super::loading::load_run_artifacts;
use super::types::{PointerState, ResolvedRunTarget, RunDiagnosticCheck};

pub(super) fn append_pointer_checks(
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

pub(super) fn append_run_checks(
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
    let loaded = load_run_artifacts(&layout, checks);

    if let (Some(metadata), Some(status)) = (loaded.metadata.as_ref(), loaded.status.as_ref()) {
        append_status_identity_checks(metadata, status, &layout, checks);
        append_status_derivation_checks(status, &layout, checks);
        append_capture_reference_checks(status, run_dir, checks);
    }

    if let (Some(status), Some(workflow)) = (loaded.status.as_ref(), loaded.workflow.as_ref()) {
        append_phase_artifact_checks(status, workflow, &layout, checks);
        append_completion_checks(status, workflow, &layout, checks);
    }

    if let Some(cluster) = loaded.cluster.as_ref() {
        append_provider_checks(cluster, checks);
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

fn append_provider_checks(cluster: &ClusterSpec, checks: &mut Vec<RunDiagnosticCheck>) {
    if cluster.provider != ClusterProvider::Remote {
        return;
    }

    for member in &cluster.members {
        let kubeconfig = Path::new(&member.kubeconfig);
        if kubeconfig.exists() {
            checks.push(ok_check(
                "run_remote_kubeconfig_present",
                "cluster",
                format!("Remote kubeconfig for `{}` is present.", member.name),
                Some(kubeconfig),
            ));
        } else {
            checks.push(error_check(
                "run_remote_kubeconfig_missing",
                "cluster",
                format!("Tracked remote kubeconfig for `{}` is missing.", member.name),
                Some(kubeconfig),
                false,
                Some(
                    "Re-run `harness setup kuma cluster ... --provider remote` to regenerate the tracked kubeconfig.",
                ),
            ));
        }
    }

    let state_path = remote_install_state_path_for_spec(cluster);
    match load_remote_install_state_for_spec(cluster) {
        Ok(Some(state)) => {
            checks.push(ok_check(
                "run_remote_install_state_present",
                "cluster",
                "Remote install state is present.",
                Some(&state_path),
            ));
            append_remote_install_state_consistency(cluster, &state, &state_path, checks);
        }
        Ok(None) => checks.push(error_check(
            "run_remote_install_state_missing",
            "cluster",
            "Remote install state is missing for a remote provider cluster.",
            Some(&state_path),
            false,
            Some(
                "Re-run remote cluster setup so harness can rebuild its tracked remote install state.",
            ),
        )),
        Err(error) => checks.push(error_check(
            "run_remote_install_state_invalid",
            "cluster",
            format!("Remote install state could not be read: {error}"),
            Some(&state_path),
            false,
            None,
        )),
    }
}

fn append_remote_install_state_consistency(
    cluster: &ClusterSpec,
    state: &RemoteKubernetesInstallState,
    state_path: &Path,
    checks: &mut Vec<RunDiagnosticCheck>,
) {
    let state_by_name = state
        .members
        .iter()
        .map(|member| (member.name.as_str(), member))
        .collect::<BTreeMap<_, _>>();

    for member in &cluster.members {
        let Some(saved) = state_by_name.get(member.name.as_str()) else {
            checks.push(error_check(
                "run_remote_install_state_member_missing",
                "cluster",
                format!(
                    "Remote install state does not include tracked member `{}`.",
                    member.name
                ),
                Some(state_path),
                false,
                None,
            ));
            continue;
        };
        if saved.generated_kubeconfig != member.kubeconfig {
            checks.push(error_check(
                "run_remote_install_state_kubeconfig_mismatch",
                "cluster",
                format!(
                    "Remote install state kubeconfig for `{}` is `{}`, expected `{}`.",
                    member.name, saved.generated_kubeconfig, member.kubeconfig
                ),
                Some(state_path),
                false,
                None,
            ));
        }
    }
}
