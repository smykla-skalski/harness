//! The `harness-panel` executable.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use harness_panel::config::{DEFAULT_LISTEN, PanelArgs};
use harness_panel::{PanelError, pairing, serve, unit};
use tokio::runtime::{Builder, Runtime};
use tracing_subscriber::EnvFilter;

/// Default unit name, matching the binary so the unit and its state directory
/// read the same in a status listing.
const DEFAULT_UNIT: &str = "harness-panel";

#[derive(Debug, Parser)]
#[command(
    name = "harness-panel",
    about = "Harness panel: GitHub sign-in and account roster",
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
    /// Claim the daemon credential the panel mints with, once.
    ///
    /// Separate from `serve` because the code is one-time: left in a unit file
    /// it would be spent on the first start and refused on every restart.
    Pair {
        #[command(flatten)]
        args: Box<PanelArgs>,
        /// File holding the one-time pairing code. A file rather than a flag
        /// value, which any local process can read out of `/proc`.
        #[arg(long, env = "HARNESS_PANEL_DAEMON_PAIR_CODE_FILE")]
        code_file: PathBuf,
    },
    /// Print the hardened systemd service for review before it is installed.
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
    /// Print the systemd socket that reserves the panel listener across
    /// service restarts.
    PrintSocketUnit {
        /// Address systemd owns and passes to the panel service.
        #[arg(long, default_value = DEFAULT_LISTEN)]
        listen: SocketAddr,
        /// Unit stem shared by the socket and service.
        #[arg(long, default_value = DEFAULT_UNIT)]
        unit: String,
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
        Command::Pair { args, code_file } => {
            let config = args.resolve()?;
            runtime()?.block_on(pairing::claim(&config, &code_file))
        }
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
        Command::PrintSocketUnit { listen, unit } => {
            print!("{}", unit::render_socket_unit(&unit, listen)?);
            Ok(())
        }
    }
}

fn serve_blocking(args: &PanelArgs) -> Result<(), PanelError> {
    let config = args.resolve()?;
    runtime()?.block_on(serve::run(config))
}

fn runtime() -> Result<Runtime, PanelError> {
    Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(PanelError::Runtime)
}
