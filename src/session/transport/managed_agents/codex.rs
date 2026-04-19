use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::protocol::{
    CodexApprovalDecision, CodexApprovalDecisionRequest, CodexSteerRequest,
};
use crate::errors::CliError;

use crate::session::transport::support::{daemon_client, print_json};

#[derive(Debug, Clone, Args)]
pub struct CodexAgentSteerArgs {
    /// Managed Codex agent ID.
    pub agent_id: String,
    /// Additional prompt or context to send to Codex.
    #[arg(long)]
    pub prompt: String,
}

impl Execute for CodexAgentSteerArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let snapshot = daemon_client()?.steer_codex_managed_agent(
            &self.agent_id,
            &CodexSteerRequest {
                prompt: self.prompt.clone(),
            },
        )?;
        print_json(&snapshot)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct CodexAgentInterruptArgs {
    /// Managed Codex agent ID.
    pub agent_id: String,
}

impl Execute for CodexAgentInterruptArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let snapshot = daemon_client()?.interrupt_codex_managed_agent(&self.agent_id)?;
        print_json(&snapshot)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct CodexAgentApprovalArgs {
    /// Managed Codex agent ID.
    pub agent_id: String,
    /// Approval request ID.
    pub approval_id: String,
    /// Resolution to apply.
    #[arg(long, value_enum)]
    pub decision: CodexApprovalDecision,
}

impl Execute for CodexAgentApprovalArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let snapshot = daemon_client()?.resolve_codex_managed_agent_approval(
            &self.agent_id,
            &self.approval_id,
            &CodexApprovalDecisionRequest {
                decision: self.decision,
            },
        )?;
        print_json(&snapshot)?;
        Ok(0)
    }
}
