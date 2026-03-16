use std::env;

use clap::Args;

use crate::bootstrap;
use crate::commands::resolve_project_dir;
use crate::errors::CliError;

/// Arguments for `harness bootstrap`.
#[derive(Debug, Clone, Args)]
pub struct BootstrapArgs {
    /// Project directory to bootstrap the wrapper for.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

/// Install or refresh the repo-aware harness wrapper.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn bootstrap(project_dir: Option<&str>) -> Result<i32, CliError> {
    let dir = resolve_project_dir(project_dir);
    let path_env = env::var("PATH").unwrap_or_default();
    bootstrap::main(&dir, &path_env)
}
