use clap::Args;

use crate::infra::io;
use harness_kernel::errors::CliError;
use harness_workspace::command_context::{AppContext, Execute};

use crate::session::transport::support::daemon_client_error;
use crate::session::wire::{ManagedAgentListResponse, ManagedAgentSnapshot};

mod acp_sessions;
mod attach;
mod codex;
#[cfg(test)]
mod daemon_routing_tests;
mod inspect;
mod start;
mod terminal;

#[allow(unused_imports)]
pub use acp_sessions::{AcpCloseSessionArgs, AcpDeleteSessionArgs, AcpSessionsArgs};
pub use attach::ManagedAgentAttachArgs;
pub use codex::{CodexAgentApprovalArgs, CodexAgentInterruptArgs, CodexAgentSteerArgs};
#[allow(unused_imports)]
pub use start::{
    AcpAgentCommand, AcpAgentStartArgs, AcpInspectArgs, CodexAgentStartArgs,
    SessionAgentStartCommand, SessionAgentsCommand, TerminalAgentStartArgs,
};
pub use terminal::{ManagedTerminalInputArgs, ManagedTerminalResizeArgs, ManagedTerminalStopArgs};

#[derive(Debug, Clone, Args)]
pub struct ManagedAgentListArgs {
    /// Session ID.
    pub session_id: String,
}

impl Execute for ManagedAgentListArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        io::validate_safe_segment(&self.session_id)?;
        let url = format!("/v1/sessions/{}/managed-agents", self.session_id);
        let response: ManagedAgentListResponse = super::support::daemon_client()?
            .get(&url, &[])
            .map_err(|error| daemon_client_error("list managed agents", &error))?;
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
        io::validate_safe_segment(&self.agent_id)?;
        let url = format!("/v1/managed-agents/{}", self.agent_id);
        let snapshot: ManagedAgentSnapshot = super::support::daemon_client()?
            .get(&url, &[])
            .map_err(|error| daemon_client_error("get managed agent", &error))?;
        super::support::print_json(&snapshot)?;
        Ok(0)
    }
}
