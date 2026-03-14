use std::env;
use std::path::PathBuf;

use crate::bootstrap;
use crate::errors::CliError;

/// Install or refresh the repo-aware harness wrapper.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(project_dir: Option<&str>) -> Result<i32, CliError> {
    let dir = project_dir.filter(|s| !s.is_empty()).map_or_else(
        || env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
        PathBuf::from,
    );

    let path_env = env::var("PATH").unwrap_or_default();
    bootstrap::main(&dir, &path_env)
}
