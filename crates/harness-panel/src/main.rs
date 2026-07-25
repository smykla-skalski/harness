//! The `harness-panel` executable.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use harness_panel::config::PanelArgs;
use harness_panel::{PanelError, serve, unit};
use tokio::runtime::Builder;
use tracing_subscriber::EnvFilter;

/// Default unit name, matching the binary so the unit and its state directory
/// read the same in a status listing.
const DEFAULT_UNIT: &str = "harness-panel";

#[derive(Debug, Parser)]
#[command(
    name = "harness-panel",
    about = "Harness panel: sign in with GitHub and manage your own pairing",
    version
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Serve the panel.
    Serve(Box<PanelArgs>),
    /// Print a hardened systemd unit for these flags, for review before it is
    /// installed.
    PrintUnit {
        #[command(flatten)]
        args: Box<PanelArgs>,
        /// Unit name, which also names the state directory.
        #[arg(long, default_value = DEFAULT_UNIT)]
        unit: String,
        /// Path the unit starts the panel from.
        #[arg(long, default_value = "/usr/local/bin/harness-panel")]
        binary_path: PathBuf,
    },
}

fn main() -> ExitCode {
    init_tracing();
    match run(Cli::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => report(&error),
    }
}

fn init_tracing() {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("harness_panel=info")),
        )
        .init();
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn report(error: &PanelError) -> ExitCode {
    tracing::error!(%error, "harness-panel failed");
    ExitCode::FAILURE
}

fn run(cli: Cli) -> Result<(), PanelError> {
    match cli.command {
        Command::Serve(args) => serve_blocking(&args),
        Command::PrintUnit {
            args,
            unit,
            binary_path,
        } => {
            // Rendering deliberately does not resolve the configuration: the
            // unit is printed on a host where the secret file may not exist yet.
            print!("{}", unit::render_unit(&unit, &binary_path, &args)?);
            Ok(())
        }
    }
}

fn serve_blocking(args: &PanelArgs) -> Result<(), PanelError> {
    let config = args.resolve()?;
    let runtime = Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|source| {
            PanelError::io("building the panel runtime for", &config.state_dir, source)
        })?;
    runtime.block_on(serve::run(config))
}
