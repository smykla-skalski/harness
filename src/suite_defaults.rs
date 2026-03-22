use std::path::{Path, PathBuf};

use crate::errors::CliError;
#[cfg(test)]
use crate::errors::CliErrorKind;
use crate::infra::io;

pub const DEFAULTS_FILE: &str = ".harness.json";

/// Persisted defaults for a suite directory.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SuiteDefaults {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo_root: Option<String>,
}

/// Path to the suite defaults file.
#[must_use]
pub fn suite_defaults_path(suite_dir: &Path) -> PathBuf {
    suite_dir.join(DEFAULTS_FILE)
}

/// Write suite defaults to disk.
///
/// # Errors
/// Returns `CliError` on IO failure.
#[cfg(test)]
pub fn write_suite_defaults(
    suite_dir: &Path,
    repo_root: Option<&Path>,
) -> Result<PathBuf, CliError> {
    io::ensure_dir(suite_dir)
        .map_err(|e| CliError::from(CliErrorKind::missing_file(e.to_string())))?;
    let payload = SuiteDefaults {
        repo_root: repo_root.map(|root| root.display().to_string()),
    };
    let path = suite_defaults_path(suite_dir);
    io::write_json_pretty(&path, &payload)?;
    Ok(path)
}

/// Load suite defaults from disk.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn load_suite_defaults(suite_dir: &Path) -> Result<Option<SuiteDefaults>, CliError> {
    let path = suite_defaults_path(suite_dir);
    if !path.is_file() {
        return Ok(None);
    }
    let value = io::read_json_typed(&path)?;
    Ok(Some(value))
}

/// Default repo root for a suite directory.
///
/// Reads the `.harness.json` file and returns the `repo_root` value if present.
#[must_use]
pub fn default_repo_root_for_suite(suite_dir: &Path) -> Option<PathBuf> {
    load_suite_defaults(suite_dir)
        .ok()
        .flatten()
        .and_then(|payload| payload.repo_root)
        .map(|repo_root| repo_root.trim().to_string())
        .filter(|repo_root| !repo_root.is_empty())
        .map(PathBuf::from)
}

#[cfg(test)]
mod tests;
