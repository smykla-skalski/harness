use std::env;

use clap::Args;

use crate::app::command_context::{AppContext, Execute, resolve_project_dir};
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::setup::wrapper;

impl Execute for BootstrapArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        bootstrap(self.project_dir.as_deref(), self.agent)
    }
}

/// Arguments for `harness bootstrap`.
#[derive(Debug, Clone, Args)]
pub struct BootstrapArgs {
    /// Project directory to bootstrap the wrapper for.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
    /// Agent configuration to generate.
    #[arg(long, value_enum, default_value_t = HookAgent::Claude)]
    pub agent: HookAgent,
}

/// Install or refresh the repo-aware harness wrapper.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn bootstrap(project_dir: Option<&str>, agent: HookAgent) -> Result<i32, CliError> {
    let dir = resolve_project_dir(project_dir);
    let path_env = env::var("PATH").unwrap_or_default();
    wrapper::main(&dir, &path_env)?;
    if !wrapper::harness_on_path(&path_env) {
        return Err(CliErrorKind::usage_error(format!(
            "`harness` is not on PATH after bootstrap; add ~/.local/bin (or your chosen install dir) before using generated {agent:?} hooks"
        ))
        .into());
    }
    let _ = wrapper::write_agent_bootstrap(&dir, agent)?;
    Ok(0)
}
