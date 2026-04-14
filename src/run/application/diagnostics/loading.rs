use crate::errors::CliError;
use crate::infra::io::read_json_typed;
use crate::kernel::topology::ClusterSpec;
use crate::run::RunStatus;
use crate::run::context::{RunLayout, RunMetadata};
use crate::run::workflow::{RunnerWorkflowState, read_runner_state, runner_state_path};

use super::helpers::{error_check, ok_check};
use super::types::{LoadedRunArtifacts, RunDiagnosticCheck};

pub(super) fn load_run_artifacts(
    layout: &RunLayout,
    checks: &mut Vec<RunDiagnosticCheck>,
) -> LoadedRunArtifacts {
    LoadedRunArtifacts {
        metadata: load_metadata_with_check(layout, checks),
        status: load_status_with_check(layout, checks),
        workflow: load_workflow_with_check(layout, checks),
        cluster: load_cluster_with_check(layout, checks),
    }
}

pub(super) fn load_required_metadata(
    layout: &RunLayout,
) -> Result<RunMetadata, Box<RunDiagnosticCheck>> {
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

pub(super) fn load_required_status(
    layout: &RunLayout,
) -> Result<RunStatus, Box<RunDiagnosticCheck>> {
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

fn load_metadata_with_check(
    layout: &RunLayout,
    checks: &mut Vec<RunDiagnosticCheck>,
) -> Option<RunMetadata> {
    match load_required_metadata(layout) {
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
    }
}

fn load_status_with_check(
    layout: &RunLayout,
    checks: &mut Vec<RunDiagnosticCheck>,
) -> Option<RunStatus> {
    match load_required_status(layout) {
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
    }
}

fn load_workflow_with_check(
    layout: &RunLayout,
    checks: &mut Vec<RunDiagnosticCheck>,
) -> Option<RunnerWorkflowState> {
    match load_workflow(layout) {
        Ok(workflow) => {
            checks.push(ok_check(
                "run_workflow_present",
                "workflow",
                "Runner workflow state is readable.",
                Some(&runner_state_path(&layout.run_dir())),
            ));
            Some(workflow)
        }
        Err(check) => {
            checks.push(*check);
            None
        }
    }
}

fn load_cluster_with_check(
    layout: &RunLayout,
    checks: &mut Vec<RunDiagnosticCheck>,
) -> Option<ClusterSpec> {
    match load_cluster_spec(layout) {
        Ok(Some(cluster)) => Some(cluster),
        Ok(None) => None,
        Err(error) => {
            checks.push(error_check(
                "run_cluster_spec_invalid",
                "cluster",
                format!("Cluster spec could not be read: {error}"),
                Some(&layout.state_dir().join("cluster.json")),
                false,
                None,
            ));
            None
        }
    }
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
