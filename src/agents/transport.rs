use clap::{Args, Subcommand};
use std::io::{Read as _, stdin};

use crate::app::command_context::{AppContext, Execute, resolve_project_dir};
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::SessionStartHookOutput;
use crate::hooks::adapters::HookAgent;
use crate::infra::exec::RUNTIME;

use super::service;

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum AgentsCommand {
    /// Register or resume the active agent session for a project.
    SessionStart(AgentSessionStartArgs),
    /// Clear the active agent session for a project.
    SessionStop(AgentSessionStopArgs),
    /// Record a prompt-submission event in the shared agent ledger.
    PromptSubmit(AgentPromptSubmitArgs),
}

impl Execute for AgentsCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::SessionStart(args) => args.execute(context),
            Self::SessionStop(args) => args.execute(context),
            Self::PromptSubmit(args) => args.execute(context),
        }
    }
}

fn read_stdin_bytes() -> Result<Vec<u8>, CliError> {
    let mut bytes = Vec::new();
    stdin().read_to_end(&mut bytes).map_err(|error| {
        CliError::from(CliErrorKind::hook_payload_invalid(format!(
            "failed to read stdin: {error}"
        )))
    })?;
    Ok(bytes)
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
        if let Some(context) = RUNTIME.block_on(service::session_start(
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
        RUNTIME.block_on(service::session_stop(
            self.agent,
            project_dir,
            self.session_id.clone(),
        ))?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct AgentPromptSubmitArgs {
    #[arg(long, value_enum)]
    pub agent: HookAgent,
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
    #[arg(long)]
    pub session_id: Option<String>,
}

impl Execute for AgentPromptSubmitArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project_dir = resolve_project_dir(self.project_dir.as_deref());
        let payload = read_stdin_bytes()?;
        RUNTIME.block_on(service::prompt_submit(
            self.agent,
            project_dir,
            self.session_id.clone(),
            payload,
        ))?;
        Ok(0)
    }
}
