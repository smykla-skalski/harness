//! The `harness-sybra` command-line surface, shared with the docs generator.

use std::net::SocketAddr;
use std::path::PathBuf;

use clap::Parser;

#[derive(Debug, Parser)]
#[command(name = "harness-sybra", version, about = "Local Harness Sybra gateway")]
pub struct Cli {
    /// Numeric loopback listener. Port zero selects an ephemeral port.
    #[arg(long, default_value = "127.0.0.1:0")]
    pub listen: SocketAddr,
    /// Numeric loopback HTTP origin of the private Sybra backend.
    #[arg(long)]
    pub upstream: String,
    /// Private bearer token presented only to the Sybra backend.
    #[arg(long)]
    pub upstream_token_file: PathBuf,
    /// Private bearer token accepted from the local browser.
    #[arg(long)]
    pub browser_token_file: PathBuf,
}
