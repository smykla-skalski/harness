use std::env;

use crate::bootstrap;
use crate::commands::resolve_project_dir;
use crate::errors::CliError;

/// Install or refresh the repo-aware harness wrapper.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn bootstrap(project_dir: Option<&str>) -> Result<i32, CliError> {
    let dir = resolve_project_dir(project_dir);
    let path_env = env::var("PATH").unwrap_or_default();
    bootstrap::main(&dir, &path_env)
}
