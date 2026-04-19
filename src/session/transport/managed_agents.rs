use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;

mod attach;
mod codex;
mod start;
mod terminal;

pub use attach::ManagedAgentAttachArgs;
pub use codex::{CodexAgentApprovalArgs, CodexAgentInterruptArgs, CodexAgentSteerArgs};
pub use start::{
    CodexAgentStartArgs, SessionAgentStartCommand, SessionAgentsCommand, TerminalAgentStartArgs,
};
pub use terminal::{ManagedTerminalInputArgs, ManagedTerminalResizeArgs, ManagedTerminalStopArgs};

#[derive(Debug, Clone, Args)]
pub struct ManagedAgentListArgs {
    /// Session ID.
    pub session_id: String,
}

impl Execute for ManagedAgentListArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let response = super::support::daemon_client()?.list_managed_agents(&self.session_id)?;
        super::support::print_json(&response)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct ManagedAgentShowArgs {
    /// Managed agent ID.
    pub agent_id: String,
}

impl Execute for ManagedAgentShowArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let snapshot = super::support::daemon_client()?.get_managed_agent(&self.agent_id)?;
        super::support::print_json(&snapshot)?;
        Ok(0)
    }
}
