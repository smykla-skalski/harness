use std::env;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::BlockRegistry;
use crate::run::application::RunApplication;
use crate::run::args::RunDirArgs;
use crate::run::context::{RunAggregate, RunRepository};
use crate::run::resolve::resolve_run_directory;
use crate::suite_defaults::default_repo_root_for_suite;
use crate::workspace::harness_data_root;

/// Resolve the repo root for `init` when not explicitly provided.
///
/// # Errors
/// Returns `CliError` if an explicit path is given but cannot be canonicalized.
pub(crate) fn resolve_init_repo_root(
    raw: Option<&str>,
    suite_dir: &Path,
) -> Result<PathBuf, CliError> {
    if let Some(r) = raw {
        return PathBuf::from(r)
            .canonicalize()
            .map_err(|e| CliErrorKind::io(format!("canonicalize repo root {r}: {e}")).into());
    }
    if let Some(default) = default_repo_root_for_suite(suite_dir) {
        return Ok(default);
    }
    Ok(env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
}

/// Resolve the run root for `init` when not explicitly provided.
///
/// Priority: explicit `--run-root` flag > `suite_dir/runs` > XDG runs directory.
pub(crate) fn resolve_run_root(raw: Option<&str>, suite_dir: Option<&Path>) -> PathBuf {
    if let Some(explicit) = raw {
        return PathBuf::from(explicit);
    }
    if let Some(directory) = suite_dir {
        return directory.join("runs");
    }
    harness_data_root().join("runs")
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
    .map(|resolved| resolved.run_dir)
}

/// Resolve a run directory and load its aggregate in one step.
///
/// # Errors
/// Returns `CliError` when the run directory cannot be resolved or loaded.
pub(crate) fn resolve_run_aggregate(args: &RunDirArgs) -> Result<RunAggregate, CliError> {
    let run_dir = resolve_run_dir(args)?;
    let repo = RunRepository;
    repo.load(&run_dir)
}

/// Resolve a run aggregate and build services with production adapters.
///
/// # Errors
/// Returns `CliError` when the run aggregate cannot be loaded.
pub(crate) fn resolve_run_application(args: &RunDirArgs) -> Result<RunApplication, CliError> {
    resolve_run_application_with_blocks(args, Arc::new(BlockRegistry::production()))
}

/// Resolve a run aggregate and build the application boundary with the provided adapters.
///
/// # Errors
/// Returns `CliError` when the run aggregate cannot be loaded.
pub(crate) fn resolve_run_application_with_blocks(
    args: &RunDirArgs,
    blocks: Arc<BlockRegistry>,
) -> Result<RunApplication, CliError> {
    let aggregate = resolve_run_aggregate(args)?;
    Ok(RunApplication::from_context_with_blocks(aggregate, blocks))
}
