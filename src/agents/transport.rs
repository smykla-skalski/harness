use clap::{Args, Subcommand};

use crate::app::command_context::{AppContext, Execute, resolve_project_dir};
use crate::errors::CliError;
use crate::hooks::SessionStartHookOutput;
use crate::hooks::adapters::HookAgent;

use super::service;

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum AgentsCommand {
    /// Register or resume the active agent session for a project.
    SessionStart(AgentSessionStartArgs),
    /// Clear the active agent session for a project.
    SessionStop(AgentSessionStopArgs),
}

impl Execute for AgentsCommand {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::SessionStart(args) => args.execute(_context),
            Self::SessionStop(args) => args.execute(_context),
        }
    }
}

#[derive(Debug, Clone, Args)]
pub struct AgentSessionStartArgs {
    #[arg(long, value_enum)]
    pub agent: HookAgent,
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
    #[arg(long)]
    pub session_id: Option<String>,
}

impl Execute for AgentSessionStartArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project_dir = resolve_project_dir(self.project_dir.as_deref());
        if let Some(context) = crate::infra::exec::RUNTIME.block_on(service::session_start(
            self.agent,
            project_dir,
            self.session_id.clone(),
        ))? {
            let output = SessionStartHookOutput::from_additional_context(&context);
            if let Ok(json) = output.to_json() {
                print!("{json}");
            }
        }
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct AgentSessionStopArgs {
    #[arg(long, value_enum)]
    pub agent: HookAgent,
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
    #[arg(long)]
    pub session_id: Option<String>,
}

impl Execute for AgentSessionStopArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project_dir = resolve_project_dir(self.project_dir.as_deref());
        crate::infra::exec::RUNTIME.block_on(service::session_stop(
            self.agent,
            project_dir,
            self.session_id.clone(),
        ))?;
        Ok(0)
    }
}
