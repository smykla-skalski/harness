//! The `harness-bridge` command-line surface, shared with the docs generator.

use clap::Parser;

use crate::daemon::bridge::BridgeCommand;

#[derive(Debug, Parser)]
#[command(name = "harness-bridge", version, about = "Harness host bridge")]
pub struct Cli {
    /// Seconds to wait before executing the command.
    #[arg(long, default_value = "0", global = true)]
    pub delay: f64,
    #[command(subcommand)]
    pub command: BridgeCommand,
}
