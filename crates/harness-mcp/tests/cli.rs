use std::path::PathBuf;

use clap::Parser;
use harness_mcp::McpCommand;

#[derive(Debug, Parser)]
#[command(name = "harness-mcp")]
struct TestCli {
    #[command(subcommand)]
    command: McpCommand,
}

#[test]
fn parses_serve_with_socket_override() {
    let cli =
        TestCli::try_parse_from(["harness-mcp", "serve", "--socket", "/tmp/harness-mcp.sock"])
            .expect("parse serve command");
    let McpCommand::Serve(args) = cli.command else {
        panic!("expected serve command");
    };
    assert_eq!(args.socket, Some(PathBuf::from("/tmp/harness-mcp.sock")));
}

#[test]
fn parses_serve_without_socket_override() {
    let cli = TestCli::try_parse_from(["harness-mcp", "serve"]).expect("parse serve command");
    let McpCommand::Serve(args) = cli.command else {
        panic!("expected serve command");
    };
    assert!(args.socket.is_none());
}
