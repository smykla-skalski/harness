//! CLI subcommand entry points for `harness mcp ...`.

use std::io;
use std::path::PathBuf;

use clap::{Args, Subcommand};
#[cfg(target_os = "macos")]
use tokio::io::{AsyncBufRead, AsyncWrite, BufReader, stdin, stdout};
#[cfg(target_os = "macos")]
use tokio::runtime::Builder;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
#[cfg(target_os = "macos")]
use crate::mcp::server::{RequestHandler, serve};

/// Model Context Protocol server commands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum McpCommand {
    /// Run the MCP server on stdio. Reads JSON-RPC 2.0 requests from
    /// stdin, writes responses to stdout.
    Serve(McpServeArgs),
}

impl Execute for McpCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Serve(args) => args.execute(context),
        }
    }
}

/// Options for `harness mcp serve`.
#[derive(Debug, Clone, Args)]
pub struct McpServeArgs {
    /// Override the accessibility registry socket path. Normally inferred
    /// from the macOS app-group container; override for unsandboxed dev.
    #[arg(long)]
    pub socket: Option<PathBuf>,
}

impl Execute for McpServeArgs {
    #[cfg(target_os = "macos")]
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        serve_macos(self)
    }

    #[cfg(not(target_os = "macos"))]
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        Err(CliError::from(CliErrorKind::workflow_io(
            "harness mcp serve requires macOS (uses CGEvent-backed input \
             helpers and the Harness Monitor app-group socket)",
        )))
    }
}

#[cfg(target_os = "macos")]
fn serve_macos(args: &McpServeArgs) -> Result<i32, CliError> {
    use std::sync::Arc;

    use crate::mcp::dispatch::Dispatcher;
    use crate::mcp::registry::RegistryClient;
    use crate::mcp::tool::ToolRegistry;
    use crate::mcp::tools::register_all;

    let client = match &args.socket {
        Some(path) => RegistryClient::with_socket_path(path.clone()),
        None => RegistryClient::new(),
    };
    let mut tools = ToolRegistry::new();
    register_all(&mut tools, Arc::new(client));
    let dispatcher = Dispatcher::new(tools);

    let runtime = Builder::new_current_thread()
        .enable_io()
        .enable_time()
        .build()
        .map_err(|error| map_io_error(&error))?;
    runtime.block_on(async move {
        let reader = BufReader::new(stdin());
        let mut writer = stdout();
        run_serve(reader, &mut writer, dispatcher).await
    })?;
    Ok(0)
}

#[cfg(target_os = "macos")]
async fn run_serve<R, W, H>(reader: R, writer: &mut W, handler: H) -> Result<(), CliError>
where
    R: AsyncBufRead + Unpin + Send,
    W: AsyncWrite + Unpin + Send,
    H: RequestHandler,
{
    serve(reader, writer, handler)
        .await
        .map_err(|error| map_io_error(&error))
}

fn map_io_error(error: &io::Error) -> CliError {
    CliError::from(CliErrorKind::workflow_io(format!(
        "mcp stdio serve: {error}"
    )))
}

#[cfg(test)]
mod transport_tests {
    use std::path::PathBuf;

    use clap::Parser;

    use super::{McpCommand, McpServeArgs};
    use crate::app::cli::{Cli, Command};

    #[test]
    fn cli_parses_harness_mcp_serve_with_socket_override() {
        let cli =
            Cli::try_parse_from(["harness", "mcp", "serve", "--socket", "/tmp/override.sock"])
                .expect("parse");
        let McpCommand::Serve(args) = match cli.command {
            Command::Mcp { command } => command,
            other => panic!("expected Mcp command, got {other:?}"),
        };
        assert_eq!(args.socket, Some(PathBuf::from("/tmp/override.sock")));
    }

    #[test]
    fn cli_parses_harness_mcp_serve_without_socket() {
        let cli = Cli::try_parse_from(["harness", "mcp", "serve"]).expect("parse");
        let McpCommand::Serve(args) = match cli.command {
            Command::Mcp { command } => command,
            other => panic!("expected Mcp command, got {other:?}"),
        };
        assert!(args.socket.is_none());
    }

    #[test]
    fn mcp_serve_args_are_cloneable_for_dispatch() {
        let args = McpServeArgs {
            socket: Some(PathBuf::from("/tmp/x.sock")),
        };
        let cloned = args.clone();
        assert_eq!(args.socket, cloned.socket);
    }
}
