use clap::{Args, Subcommand};

use crate::agents::assets::{AgentAssetTarget, generate_agent_assets};
use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum AgentsSetupCommand {
    /// Generate checked-in multi-agent skills and plugin assets.
    Generate(GenerateAgentAssetsArgs),
}

impl Execute for AgentsSetupCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Generate(args) => args.execute(context),
        }
    }
}

#[derive(Debug, Clone, Args)]
pub struct GenerateAgentAssetsArgs {
    /// Fail if generated output differs from the checked-in files.
    #[arg(long)]
    pub check: bool,
    /// Limit generation to a single target.
    #[arg(long, value_enum, default_value_t = AgentAssetTarget::All)]
    pub target: AgentAssetTarget,
}

impl Execute for GenerateAgentAssetsArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        generate_agent_assets(self.target, self.check)
    }
}
