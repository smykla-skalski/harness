use std::env;

use clap::Args;

use crate::app::command_context::{AppContext, Execute, resolve_project_dir};
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::setup::wrapper;

impl Execute for BootstrapArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        bootstrap_with_skipped_runtime_hooks(
            self.project_dir.as_deref(),
            &self.agents,
            &self.skip_runtime_hooks,
            self.include_gemini_commands,
        )
    }
}

/// Arguments for `harness bootstrap`.
#[derive(Debug, Clone, Args)]
pub struct BootstrapArgs {
    /// Project directory to bootstrap the wrapper for.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
    /// Agents to bootstrap. Defaults to every supported agent.
    #[arg(long, value_enum, value_delimiter = ',', num_args = 1..)]
    pub agents: Vec<HookAgent>,
    /// Skip runtime hook config files for the listed agents while bootstrapping.
    #[arg(long, value_enum, value_delimiter = ',', num_args = 1..)]
    pub skip_runtime_hooks: Vec<HookAgent>,
    /// Also emit Gemini `.gemini/commands/**` command wrappers.
    #[arg(long)]
    pub include_gemini_commands: bool,
}

const BOOTSTRAP_AGENT_ORDER: [HookAgent; 6] = [
    HookAgent::Claude,
    HookAgent::Codex,
    HookAgent::Gemini,
    HookAgent::Copilot,
    HookAgent::Vibe,
    HookAgent::OpenCode,
];

/// Install or refresh the repo-aware harness wrapper.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn bootstrap(project_dir: Option<&str>, agents: &[HookAgent]) -> Result<i32, CliError> {
    bootstrap_with_skipped_runtime_hooks(project_dir, agents, &[], false)
}

fn bootstrap_with_skipped_runtime_hooks(
    project_dir: Option<&str>,
    agents: &[HookAgent],
    skip_runtime_hooks: &[HookAgent],
    include_gemini_commands: bool,
) -> Result<i32, CliError> {
    let dir = resolve_project_dir(project_dir);
    let path_env = env::var("PATH").unwrap_or_default();
    wrapper::main(&dir, &path_env)?;
    if !wrapper::harness_on_path(&path_env) {
        return Err(CliErrorKind::usage_error(
            "`harness` is not on PATH after bootstrap; add ~/.local/bin (or your chosen install dir) before using generated hook configs"
                .to_string(),
        )
        .into());
    }
    for agent in selected_agents(agents) {
        let _ = wrapper::write_agent_bootstrap(
            &dir,
            agent,
            include_gemini_commands,
            skip_runtime_hooks,
        )?;
    }
    Ok(0)
}

pub(crate) fn selected_agents(requested: &[HookAgent]) -> Vec<HookAgent> {
    if requested.is_empty() {
        return BOOTSTRAP_AGENT_ORDER.to_vec();
    }

    BOOTSTRAP_AGENT_ORDER
        .into_iter()
        .filter(|agent| requested.contains(agent))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{HookAgent, selected_agents};

    #[test]
    fn selected_agents_defaults_to_all_supported_agents() {
        assert_eq!(
            selected_agents(&[]),
            vec![
                HookAgent::Claude,
                HookAgent::Codex,
                HookAgent::Gemini,
                HookAgent::Copilot,
                HookAgent::Vibe,
                HookAgent::OpenCode,
            ]
        );
    }

    #[test]
    fn selected_agents_returns_canonical_subset_order() {
        assert_eq!(
            selected_agents(&[HookAgent::OpenCode, HookAgent::Claude, HookAgent::Codex]),
            vec![HookAgent::Claude, HookAgent::Codex, HookAgent::OpenCode]
        );
    }
}
