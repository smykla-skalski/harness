//! ACP shim binary for OpenRouter.
//!
//! The harness daemon spawns this binary as a supervised stdio child (see
//! `src/agents/acp/catalog/openrouter.rs`). The child speaks ACP JSON-RPC over
//! its stdin/stdout pair; this entry-point delegates to [`harness_openrouter_agent::acp::run_stdio`]
//! after setting up `tracing` to stderr so log lines never pollute the JSON-RPC
//! channel.
//!
//! `--probe` returns immediately so `harness doctor` can detect the binary
//! without bringing up the full async runtime.
//!
//! The OpenRouter API key arrives via `--api-key-file PATH`: the daemon
//! creates a mode-0600 file in a per-spawn random tempdir, writes the key
//! from its Monitor-synced in-memory cache, and the bridge reads + immediately
//! unlinks it inside `run_stdio`. Environment variables are deliberately NOT
//! a delivery channel — they leak to grand-children and show up in
//! `/proc/<pid>/environ`.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;

/// Entry-point CLI surface. The harness daemon launches the binary with
/// `--stdio --api-key-file PATH`; the catalog descriptor's doctor probe uses
/// `--probe`.
#[derive(Debug, Parser)]
#[command(name = "harness-openrouter-agent", version)]
struct Cli {
    /// Speak ACP over stdin/stdout. The default mode used by the daemon.
    #[arg(long, default_value_t = true)]
    stdio: bool,

    /// Print success and exit. Used by `harness doctor` to detect installation.
    #[arg(long, conflicts_with = "stdio")]
    probe: bool,

    /// Path to a mode-0600 file containing the OpenRouter API key. The shim
    /// reads the file then immediately unlinks it. The daemon prepares this
    /// file from its in-memory token cache before each spawn.
    #[arg(long, conflicts_with = "probe")]
    api_key_file: Option<PathBuf>,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    if cli.probe {
        return ExitCode::SUCCESS;
    }
    if let Err(error) = init_tracing() {
        eprintln!("failed to initialise tracing: {error}");
        return ExitCode::from(2);
    }
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("failed to build tokio runtime: {error}");
            return ExitCode::from(2);
        }
    };
    match runtime.block_on(harness_openrouter_agent::acp::run_stdio(cli.api_key_file)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            tracing::error!(%error, "openrouter ACP bridge exited with error");
            ExitCode::from(1)
        }
    }
}

fn init_tracing() -> Result<(), String> {
    use tracing_subscriber::EnvFilter;
    let filter = EnvFilter::try_from_env("HARNESS_OPENROUTER_LOG")
        .unwrap_or_else(|_| EnvFilter::new("harness_openrouter_agent=info,warn"));
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(filter)
        .try_init()
        .map_err(|error| error.to_string())
}
