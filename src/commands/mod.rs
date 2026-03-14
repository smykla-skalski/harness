use std::env;
use std::path::PathBuf;

use crate::cli::RunDirArgs;
use crate::context::RunLookup;
use crate::errors::CliError;
use crate::resolve::resolve_run_directory;

pub mod apply;
pub mod approval_begin;
pub mod authoring_begin;
pub mod authoring_reset;
pub mod authoring_save;
pub mod authoring_show;
pub mod authoring_validate;
pub mod bootstrap;
pub mod capture;
pub mod closeout;
pub mod cluster;
pub mod diff;
pub mod envoy;
pub mod gateway;
pub mod init_run;
pub mod kumactl;
pub mod pre_compact;
pub mod preflight;
pub mod record;
pub mod report;
pub mod runner_state;
pub mod session_start;
pub mod session_stop;
pub mod validate;

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
    resolve_run_directory(&RunLookup {
        run_dir: args.run_dir.clone(),
        run_id: args.run_id.clone(),
        run_root: args.run_root.clone(),
    })
    .map(|r| r.run_dir)
}
