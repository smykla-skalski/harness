use clap::{Args, Subcommand};

use crate::app::command_context::{CommandContext, Execute};
use crate::errors::CliError;

use super::ClusterArgs;

/// Kuma-specific setup commands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum KumaSetupCommand {
    Cluster(ClusterArgs),
}

/// Arguments for `harness setup kuma`.
#[derive(Debug, Clone, Args)]
pub struct KumaSetupArgs {
    /// Kuma setup subcommand.
    #[command(subcommand)]
    pub command: KumaSetupCommand,
}

impl Execute for KumaSetupArgs {
    fn execute(&self, context: &CommandContext) -> Result<i32, CliError> {
        match &self.command {
            KumaSetupCommand::Cluster(args) => args.execute(context),
        }
    }
}
