use clap::Args;

use harness_kernel::io;
use harness_kernel::errors::CliError;
use harness_protocol::managed_agents::codex::{
    CodexApprovalDecision, CodexApprovalDecisionRequest, CodexSteerRequest,
};
use harness_workspace::command_context::{AppContext, Execute};

use crate::transport::support::{daemon_client, daemon_client_error, print_json};
use crate::wire::ManagedAgentSnapshot;

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
        io::validate_safe_segment(&self.agent_id)?;
        let request = CodexSteerRequest {
            prompt: self.prompt.clone(),
        };
        let url = format!("/v1/managed-agents/{}/steer", self.agent_id);
        let snapshot: ManagedAgentSnapshot = daemon_client()?
            .post(&url, &request)
            .map_err(|error| daemon_client_error("steer managed Codex agent", &error))?;
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
        io::validate_safe_segment(&self.agent_id)?;
        let url = format!("/v1/managed-agents/{}/interrupt", self.agent_id);
        let snapshot: ManagedAgentSnapshot = daemon_client()?
            .post(&url, &serde_json::json!({}))
            .map_err(|error| daemon_client_error("interrupt managed Codex agent", &error))?;
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
        io::validate_safe_segment(&self.agent_id)?;
        io::validate_safe_segment(&self.approval_id)?;
        let request = CodexApprovalDecisionRequest {
            decision: self.decision,
        };
        let url = format!(
            "/v1/managed-agents/{}/approvals/{}",
            self.agent_id, self.approval_id
        );
        let snapshot: ManagedAgentSnapshot = daemon_client()?
            .post(&url, &request)
            .map_err(|error| daemon_client_error("resolve managed Codex approval", &error))?;
        print_json(&snapshot)?;
        Ok(0)
    }
}
