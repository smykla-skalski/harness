use std::path::PathBuf;

use crate::errors::CliError;

/// Install or refresh the repo-aware harness wrapper.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(project_dir: Option<&str>) -> Result<i32, CliError> {
    let dir = project_dir
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));

    let path_env = std::env::var("PATH").unwrap_or_default();
    crate::bootstrap::main(&dir, &path_env)
}
