use std::env;

use clap::Args;

use crate::bootstrap;
use crate::commands::resolve_project_dir;
use crate::errors::{CliError, CliErrorKind, cow};
use crate::hooks::adapters::HookAgent;

/// Arguments for `harness bootstrap`.
#[derive(Debug, Clone, Args)]
pub struct BootstrapArgs {
    /// Project directory to bootstrap the wrapper for.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
    /// Agent configuration to generate.
    #[arg(long, value_enum, default_value_t = HookAgent::ClaudeCode)]
    pub agent: HookAgent,
}

/// Install or refresh the repo-aware harness wrapper.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn bootstrap(project_dir: Option<&str>, agent: HookAgent) -> Result<i32, CliError> {
    let dir = resolve_project_dir(project_dir);
    let path_env = env::var("PATH").unwrap_or_default();
    bootstrap::main(&dir, &path_env)?;
    if !bootstrap::harness_on_path(&path_env) {
        return Err(CliErrorKind::usage_error(cow!(
            "`harness` is not on PATH after bootstrap; add ~/.local/bin (or your chosen install dir) before using generated {agent:?} hooks"
        ))
        .into());
    }
    let _ = bootstrap::write_agent_bootstrap(&dir, agent)?;
    Ok(0)
}
