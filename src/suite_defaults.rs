use std::path::{Path, PathBuf};

use crate::errors::CliError;

pub const DEFAULTS_FILE: &str = ".harness.json";

/// Path to the suite defaults file.
#[must_use]
pub fn suite_defaults_path(suite_dir: &Path) -> PathBuf {
    suite_dir.join(DEFAULTS_FILE)
}

/// Write suite defaults to disk.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn write_suite_defaults(
    _suite_dir: &Path,
    _repo_root: Option<&Path>,
) -> Result<PathBuf, CliError> {
    todo!()
}

/// Load suite defaults from disk.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn load_suite_defaults(_suite_dir: &Path) -> Result<Option<serde_json::Value>, CliError> {
    todo!()
}

/// Find the suite directory containing a path.
#[must_use]
pub fn find_suite_dir(_path: &Path) -> Option<PathBuf> {
    todo!()
}

/// Default repo root for a suite directory.
#[must_use]
pub fn default_repo_root_for_suite(_suite_dir: &Path) -> Option<PathBuf> {
    todo!()
}

#[cfg(test)]
mod tests {}
