use std::env;
use std::path::PathBuf;

use clap::{Args, Subcommand, ValueEnum};

use crate::config_patch::{SyncMode, sync_runtime_configs};
use crate::hook_agent::HookAgent;

#[derive(Debug, Clone, Subcommand)]
pub enum SetupCommand {
    Bootstrap(SetupBootstrapArgs),
    Agents(SetupAgentsArgs),
}

#[derive(Debug, Clone, Args)]
pub struct SetupBootstrapArgs {
    /// Project directory whose runtime configs should be patched after harness bootstrap.
    #[arg(long)]
    pub project_dir: Option<String>,
    /// Agents to patch. Defaults to every supported runtime.
    #[arg(long, value_enum, value_delimiter = ',', num_args = 1..)]
    pub agents: Vec<HookAgent>,
    /// Skip runtime hook configs for the listed agents.
    #[arg(long, value_enum, value_delimiter = ',', num_args = 1..)]
    pub skip_runtime_hooks: Vec<HookAgent>,
    /// Accepted for task-surface parity with harness; aff does not emit Gemini commands.
    #[arg(long)]
    pub include_gemini_commands: bool,
    /// Accepted for task-surface parity with harness; aff does not gate on suite hooks.
    #[arg(long)]
    pub enable_suite_hooks: bool,
}

#[derive(Debug, Clone, Args)]
pub struct SetupAgentsArgs {
    #[command(subcommand)]
    pub command: SetupAgentsCommand,
}

#[derive(Debug, Clone, Subcommand)]
pub enum SetupAgentsCommand {
    Generate(GenerateRuntimeHooksArgs),
}

#[derive(Debug, Clone, Args)]
pub struct GenerateRuntimeHooksArgs {
    /// Fail if aff-owned runtime hook entries differ from the on-disk files.
    #[arg(long)]
    pub check: bool,
    /// Project directory whose runtime configs should be patched after harness generation.
    #[arg(long)]
    pub project_dir: Option<String>,
    /// Limit aff runtime patching to a single target.
    #[arg(long, value_enum, default_value_t = RuntimeHookTarget::All)]
    pub target: RuntimeHookTarget,
    /// Skip runtime hook configs for the listed agents.
    #[arg(long, value_enum, value_delimiter = ',', num_args = 1..)]
    pub skip_runtime_hooks: Vec<HookAgent>,
    /// Accepted for task-surface parity with harness; aff does not emit Gemini commands.
    #[arg(long)]
    pub include_gemini_commands: bool,
    /// Accepted for task-surface parity with harness; aff does not gate on suite hooks.
    #[arg(long)]
    pub enable_suite_hooks: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
#[value(rename_all = "kebab-case")]
pub enum RuntimeHookTarget {
    All,
    Claude,
    Copilot,
    Codex,
    Gemini,
    Vibe,
    OpenCode,
}

pub fn run(command: SetupCommand) -> Result<i32, String> {
    match command {
        SetupCommand::Bootstrap(args) => args.execute(),
        SetupCommand::Agents(args) => args.execute(),
    }
}

impl SetupBootstrapArgs {
    fn execute(self) -> Result<i32, String> {
        let project_dir = resolve_project_dir(self.project_dir.as_deref())?;
        let agents = selected_agents(&self.agents);
        sync_runtime_configs(
            &project_dir,
            &agents,
            &self.skip_runtime_hooks,
            SyncMode::Apply,
        )?;
        Ok(0)
    }
}

impl SetupAgentsArgs {
    fn execute(self) -> Result<i32, String> {
        match self.command {
            SetupAgentsCommand::Generate(args) => args.execute(),
        }
    }
}

impl GenerateRuntimeHooksArgs {
    fn execute(self) -> Result<i32, String> {
        let project_dir = resolve_project_dir(self.project_dir.as_deref())?;
        let agents = self.target.selected_agents();
        sync_runtime_configs(
            &project_dir,
            &agents,
            &self.skip_runtime_hooks,
            if self.check {
                SyncMode::Check
            } else {
                SyncMode::Apply
            },
        )?;
        Ok(0)
    }
}

impl RuntimeHookTarget {
    fn selected_agents(self) -> Vec<HookAgent> {
        match self {
            Self::All => HookAgent::ALL.to_vec(),
            Self::Claude => vec![HookAgent::Claude],
            Self::Copilot => vec![HookAgent::Copilot],
            Self::Codex => vec![HookAgent::Codex],
            Self::Gemini => vec![HookAgent::Gemini],
            Self::Vibe => vec![HookAgent::Vibe],
            Self::OpenCode => vec![HookAgent::OpenCode],
        }
    }
}

fn selected_agents(requested: &[HookAgent]) -> Vec<HookAgent> {
    if requested.is_empty() {
        return HookAgent::ALL.to_vec();
    }

    HookAgent::ALL
        .into_iter()
        .filter(|agent| requested.contains(agent))
        .collect()
}

fn resolve_project_dir(project_dir: Option<&str>) -> Result<PathBuf, String> {
    if let Some(project_dir) = project_dir {
        return Ok(PathBuf::from(project_dir));
    }

    env::current_dir().map_err(|error| format!("failed to resolve current directory: {error}"))
}
