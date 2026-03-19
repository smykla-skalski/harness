use clap::{Args, Subcommand};

use crate::app::command_context::{CommandContext, Execute};
use crate::errors::CliError;

use super::{ApiArgs, KumactlArgs, ServiceArgs, TokenArgs};

/// Kuma-specific run commands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum KumaCommand {
    Api(ApiArgs),
    Cli(KumactlArgs),
    Service(ServiceArgs),
    Token(TokenArgs),
}

/// Arguments for `harness run kuma`.
#[derive(Debug, Clone, Args)]
pub struct KumaArgs {
    /// Kuma subcommand.
    #[command(subcommand)]
    pub command: KumaCommand,
}

impl Execute for KumaArgs {
    fn execute(&self, context: &CommandContext) -> Result<i32, CliError> {
        match &self.command {
            KumaCommand::Api(args) => args.execute(context),
            KumaCommand::Cli(args) => args.execute(context),
            KumaCommand::Service(args) => args.execute(context),
            KumaCommand::Token(args) => args.execute(context),
        }
    }
}
