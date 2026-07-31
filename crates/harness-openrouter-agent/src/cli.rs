//! The `harness-openrouter-agent` command-line surface, shared with the docs
//! generator.

use std::path::PathBuf;

use clap::Parser;

/// Entry-point CLI surface. The harness daemon launches the binary with
/// `--stdio --api-key-file PATH`; the catalog descriptor's doctor probe uses
/// `--probe`.
#[derive(Debug, Parser)]
#[command(name = "harness-openrouter-agent", version)]
pub struct Cli {
    /// Speak ACP over stdin/stdout. The default mode used by the daemon.
    #[arg(long, default_value_t = true)]
    pub stdio: bool,

    /// Print success and exit. Used by `harness doctor` to detect installation.
    #[arg(long, conflicts_with = "stdio")]
    pub probe: bool,

    /// Path to a mode-0600 file containing the OpenRouter API key. The shim
    /// reads the file then immediately unlinks it. The daemon prepares this
    /// file from its in-memory token cache before each spawn.
    #[arg(long, conflicts_with = "probe")]
    pub api_key_file: Option<PathBuf>,
}
