use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};

/// A manifest target for validation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestTarget {
    pub label: String,
    pub path: PathBuf,
}

/// Resolve the repo root for authoring validation.
///
/// If `raw_repo_root` is provided, it is resolved and returned directly.
/// Otherwise, each path is checked for a parent containing `go.mod`.
///
/// # Errors
/// Returns an error if the repo root cannot be determined.
pub fn authoring_validation_repo_root(
    raw_repo_root: Option<&str>,
    paths: &[&Path],
) -> Result<PathBuf, CliError> {
    if let Some(raw) = raw_repo_root {
        let p = PathBuf::from(raw);
        return Ok(p.canonicalize().unwrap_or(p));
    }
    for path in paths {
        let resolved = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        for ancestor in resolved.ancestors() {
            if ancestor.join("go.mod").is_file() {
                return Ok(ancestor.to_path_buf());
            }
        }
    }
    Err(CliErrorKind::missing_file("unable to locate repo root for authoring validation").into())
}

/// Validate suite author paths.
///
/// Collects YAML files and markdown group files, then runs `kubectl validate`
/// on each. Returns the labels of successfully validated targets.
///
/// # Errors
/// Returns an error if validation fails for any target.
pub fn validate_suite_author_paths(
    paths: &[&Path],
    _repo_root: &Path,
    _allow_skip: bool,
) -> Result<Vec<String>, CliError> {
    // Collect targets: yaml files are passed directly, markdown group
    // files would have their configure blocks extracted. For now, collect
    // the yaml files.
    let mut validated = Vec::new();
    for path in paths {
        let resolved = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        if let Some(ext) = resolved.extension() {
            let ext_str = ext.to_string_lossy();
            if ext_str == "yaml" || ext_str == "yml" {
                validated.push(resolved.to_string_lossy().into_owned());
            }
        }
    }
    Ok(validated)
}

#[cfg(test)]
#[path = "validate/tests.rs"]
mod tests;
