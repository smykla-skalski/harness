//! The `harness-mcp` command-line surface, shared with the docs generator.

use clap::Parser;

use crate::McpCommand;

#[derive(Debug, Parser)]
#[command(name = "harness-mcp", version, about = "Harness MCP server")]
pub struct Cli {
    /// Seconds to wait before executing the command.
    #[arg(long, default_value = "0", global = true)]
    pub delay: f64,
    #[command(subcommand)]
    pub command: McpCommand,
}
