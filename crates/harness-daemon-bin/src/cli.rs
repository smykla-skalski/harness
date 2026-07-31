//! The `harness-daemon` command-line surface, shared with the docs generator.

use clap::Parser;
use harness_daemon_cli::DaemonCommand;

#[derive(Debug, Parser)]
#[command(name = "harness-daemon", version, about = "Harness daemon")]
pub struct Cli {
    /// Seconds to wait before executing the command.
    #[arg(long, default_value = "0", global = true)]
    pub delay: f64,
    #[command(subcommand)]
    pub command: DaemonCommand,
}
