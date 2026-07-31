//! The `harness-panel` executable.

use std::process::ExitCode;

use clap::Parser;
use harness_panel::cli::{Cli, Command};
use harness_panel::config::PanelArgs;
use harness_panel::{PanelError, pairing, serve, unit};
use tokio::runtime::{Builder, Runtime};
use tracing_subscriber::EnvFilter;

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
