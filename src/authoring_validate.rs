use std::path::{Path, PathBuf};

/// A manifest target for validation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestTarget {
    pub label: String,
    pub path: PathBuf,
}

/// Resolve the repo root for authoring validation.
///
/// # Errors
/// Returns an error if the repo root cannot be determined.
pub fn authoring_validation_repo_root(
    _raw_repo_root: Option<&str>,
    _paths: &[&Path],
) -> Result<PathBuf, crate::errors::CliError> {
    todo!()
}

/// Validate suite author paths.
///
/// # Errors
/// Returns an error if validation fails.
pub fn validate_suite_author_paths(
    _paths: &[&Path],
    _repo_root: &Path,
    _allow_skip: bool,
) -> Result<Vec<String>, crate::errors::CliError> {
    todo!()
}

#[cfg(test)]
mod tests {}
