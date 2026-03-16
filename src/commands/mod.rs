use std::env;
use std::path::PathBuf;

use crate::context::{RunAggregate, RunContext, RunRepository};
use crate::errors::{CliError, CliErrorKind};
use crate::resolve::resolve_run_directory;
use crate::runtime::ClusterRuntime;

pub mod args;
pub mod authoring;
pub mod observe;
pub mod run;
pub mod setup;
pub use args::RunDirArgs;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Resolve the repository root from an optional CLI argument, falling back to
/// the current working directory.
pub(crate) fn resolve_repo_root(raw: Option<&str>) -> PathBuf {
    raw.map_or_else(
        || env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
        PathBuf::from,
    )
}

/// Resolve a run directory from CLI arguments.
///
/// # Errors
/// Returns `CliError` when the run directory cannot be resolved.
pub(crate) fn resolve_run_dir(args: &RunDirArgs) -> Result<PathBuf, CliError> {
    resolve_run_directory(
        args.run_dir.as_deref(),
        args.run_id.as_deref(),
        args.run_root.as_deref(),
    )
    .map(|r| r.run_dir)
}

/// Resolve a project directory from an optional CLI argument, falling back to
/// the current working directory.
pub(crate) fn resolve_project_dir(raw: Option<&str>) -> PathBuf {
    raw.filter(|s| !s.is_empty()).map_or_else(
        || env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
        PathBuf::from,
    )
}

/// Resolve a run directory and load its context in one step.
///
/// # Errors
/// Returns `CliError` when the run directory cannot be resolved or its
/// context cannot be loaded.
pub(crate) fn resolve_run_context(args: &RunDirArgs) -> Result<RunContext, CliError> {
    resolve_run_aggregate(args)
}

/// Resolve a run directory and load its aggregate in one step.
///
/// # Errors
/// Returns `CliError` when the run directory cannot be resolved or its
/// aggregate cannot be loaded.
pub(crate) fn resolve_run_aggregate(args: &RunDirArgs) -> Result<RunAggregate, CliError> {
    let run_dir = resolve_run_dir(args)?;
    let repo = RunRepository;
    repo.load(&run_dir)
}

/// Resolve the runtime access model for a run aggregate.
///
/// Returns `None` when the run has no persisted cluster spec yet.
#[must_use]
pub(crate) fn resolve_cluster_runtime(ctx: &RunAggregate) -> Option<ClusterRuntime> {
    ctx.cluster
        .as_ref()
        .and_then(|spec| ClusterRuntime::from_spec(spec).ok())
}

/// Resolve a kubeconfig path from explicit argument, cluster name, or the
/// primary cluster config in the run context.
///
/// # Errors
/// Returns `CliError` when no kubeconfig can be determined.
pub(crate) fn resolve_kubeconfig(
    ctx: &RunAggregate,
    explicit: Option<&str>,
    cluster: Option<&str>,
) -> Result<PathBuf, CliError> {
    if let Some(runtime) = resolve_cluster_runtime(ctx) {
        return runtime.resolve_kubeconfig(explicit, cluster);
    }
    Err(CliErrorKind::missing_run_context_value("kubeconfig").into())
}
