use std::collections::HashMap;
use std::path::Path;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::exec::{run_command, run_command_streaming};
use crate::kernel::topology::{ClusterSpec, Platform};
use crate::run::application::RunApplication;
use crate::setup::cluster::ClusterArgs;
use crate::setup::cluster::kubernetes::cluster_k8s;
#[cfg(feature = "compose")]
use crate::setup::cluster::universal::cluster_universal;

pub(crate) fn make_target(
    root: &Path,
    target: &str,
    env: &HashMap<String, String>,
) -> Result<(), CliError> {
    run_command(&["make", target], Some(root), Some(env), &[0])?;
    Ok(())
}

pub(crate) fn make_target_live(
    root: &Path,
    target: &str,
    env: &HashMap<String, String>,
) -> Result<(), CliError> {
    run_command_streaming(&["make", target], Some(root), Some(env), &[0])?;
    Ok(())
}

/// Manage disposable local clusters (k3d or universal Docker).
///
/// # Errors
/// Returns `CliError` on failure.
pub(crate) fn execute_cluster(args: &ClusterArgs) -> Result<i32, CliError> {
    let platform: Platform = args
        .platform
        .parse()
        .map_err(|error: String| CliError::from(CliErrorKind::usage_error(error)))?;

    match platform {
        Platform::Kubernetes => cluster_k8s(args),
        #[cfg(feature = "compose")]
        Platform::Universal => cluster_universal(args),
        #[cfg(not(feature = "compose"))]
        Platform::Universal => Err(CliError::from(CliErrorKind::usage_error(
            "universal platform requires the 'compose' feature",
        ))),
    }
}

/// Persist cluster spec to the session context and run directory if available.
pub(crate) fn persist_cluster_spec(spec: &ClusterSpec) -> Result<(), CliError> {
    persist_cluster_spec_to_run(spec)?;
    Ok(())
}

fn persist_cluster_spec_to_run(spec: &ClusterSpec) -> Result<(), CliError> {
    if RunApplication::current_run_dir()?.is_none() {
        return Ok(());
    }
    RunApplication::persist_current_cluster_spec(spec)?;
    Ok(())
}
