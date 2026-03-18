use std::io;
use std::process::ExitCode;

use tracing_subscriber::EnvFilter;
use tracing_subscriber::fmt::time::ChronoUtc;

use harness::app::cli;
use harness::errors;

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_writer(io::stderr)
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("harness=info")),
        )
        .with_target(false)
        .with_timer(ChronoUtc::rfc_3339())
        .init();

    match cli::run() {
        Ok(code) => ExitCode::from(u8::try_from(code).unwrap_or(1)),
        Err(error) => {
            eprintln!("{}", errors::render_error(&error));
            ExitCode::from(u8::try_from(error.exit_code()).unwrap_or(1))
        }
    }
}
