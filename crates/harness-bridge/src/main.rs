use std::process::ExitCode;
use std::thread;
use std::time::Duration;

use clap::Parser;
use harness_bridge::app::{AppContext, Execute};
use harness_bridge::daemon::bridge::BridgeCommand;
use harness_bridge::errors;
use harness_telemetry::{RuntimeService, init_tracing_subscriber_for};

#[derive(Debug, Parser)]
#[command(name = "harness-bridge", version, about = "Harness host bridge")]
struct Cli {
    /// Seconds to wait before executing the command.
    #[arg(long, default_value = "0", global = true)]
    delay: f64,
    #[command(subcommand)]
    command: BridgeCommand,
}

fn main() -> ExitCode {
    let telemetry_guard = match init_tracing_subscriber_for(RuntimeService::Bridge) {
        Ok(guard) => guard,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::FAILURE;
        }
    };
    let cli = Cli::parse();
    if cli.delay > 0.0 {
        thread::sleep(Duration::from_secs_f64(cli.delay));
    }
    harness_bridge::app::run_startup_migrations();
    let result = cli.command.execute(&AppContext::production());
    drop(telemetry_guard);
    match result {
        Ok(code) => exit_code(code),
        Err(error) => render_error(&error),
    }
}

fn render_error(error: &errors::CliError) -> ExitCode {
    eprintln!("{}", errors::render_error(error));
    exit_code(error.exit_code())
}

fn exit_code(code: i32) -> ExitCode {
    ExitCode::from(u8::try_from(code).unwrap_or(1))
}
