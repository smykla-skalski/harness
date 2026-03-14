use std::path::PathBuf;

use crate::context::RunLookup;
use crate::errors::CliError;

/// Resolved run directory.
#[derive(Debug, Clone)]
pub struct ResolvedRun {
    pub run_dir: PathBuf,
}

/// Resolve a run directory from a lookup.
///
/// # Errors
/// Returns `CliError` if the run directory cannot be determined.
pub fn resolve_run_directory(_lookup: &RunLookup) -> Result<ResolvedRun, CliError> {
    todo!()
}

/// Resolve a suite path from raw input.
///
/// # Errors
/// Returns `CliError` if not found.
pub fn resolve_suite_path(_raw: &str) -> Result<PathBuf, CliError> {
    todo!()
}

/// Resolve a manifest path.
///
/// # Errors
/// Returns `CliError` if not found.
pub fn resolve_manifest_path(
    _raw: &str,
    _run_dir: Option<&std::path::Path>,
) -> Result<PathBuf, CliError> {
    todo!()
}

#[cfg(test)]
mod tests {}
