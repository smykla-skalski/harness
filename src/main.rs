use std::process::ExitCode;

use harness::app::cli;
use harness::errors;

fn main() -> ExitCode {
    let telemetry_guard = match harness::telemetry::init_tracing_subscriber() {
        Ok(guard) => guard,
        Err(error) => {
            eprintln!("{}", errors::render_error(&error));
            return ExitCode::from(u8::try_from(error.exit_code()).unwrap_or(1));
        }
    };

    let exit_code = match cli::run() {
        Ok(code) => ExitCode::from(u8::try_from(code).unwrap_or(1)),
        Err(error) => {
            eprintln!("{}", errors::render_error(&error));
            ExitCode::from(u8::try_from(error.exit_code()).unwrap_or(1))
        }
    };

    drop(telemetry_guard);
    exit_code
}
