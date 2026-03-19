use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::authoring::application::AuthoringApplication;
use crate::errors::CliError;

impl Execute for AuthoringValidateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        validate(&self.path, self.repo_root.as_deref())
    }
}

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
    let validated = AuthoringApplication::validate_paths(paths, repo_root)?;
    for label in &validated {
        println!("{label}");
    }
    Ok(0)
}
