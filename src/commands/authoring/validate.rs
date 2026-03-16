use std::path::{Path, PathBuf};

use clap::Args;

use crate::authoring_validate::{authoring_validation_repo_root, validate_suite_author_paths};
use crate::errors::CliError;

/// Arguments for `harness authoring-validate`.
#[derive(Debug, Clone, Args)]
pub struct AuthoringValidateArgs {
    /// Manifest or group Markdown path; repeat for multiple inputs.
    #[arg(long, required = true)]
    pub path: Vec<String>,
    /// Repo root for locating checked-in CRDs.
    #[arg(long)]
    pub repo_root: Option<String>,
}

/// Validate authored manifests against local CRDs.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn validate(paths: &[String], repo_root: Option<&str>) -> Result<i32, CliError> {
    let path_refs: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
    let path_slices: Vec<&Path> = path_refs.iter().map(PathBuf::as_path).collect();

    let root = authoring_validation_repo_root(repo_root, &path_slices)?;

    let validated = validate_suite_author_paths(&path_slices, &root, false)?;

    for label in &validated {
        println!("{label}");
    }
    Ok(0)
}
