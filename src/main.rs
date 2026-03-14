use std::process::ExitCode;

use harness::cli;
use harness::errors;

fn main() -> ExitCode {
    match cli::run() {
        Ok(code) => ExitCode::from(u8::try_from(code).unwrap_or(1)),
        Err(error) => {
            eprintln!("{}", errors::render_error(&error));
            ExitCode::from(u8::try_from(error.exit_code).unwrap_or(1))
        }
    }
}
