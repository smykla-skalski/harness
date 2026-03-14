use std::process::ExitCode;

fn main() -> ExitCode {
    match harness::cli::run() {
        Ok(code) => ExitCode::from(u8::try_from(code).unwrap_or(1)),
        Err(error) => {
            eprintln!("{}", harness::errors::render_error(&error));
            ExitCode::from(u8::try_from(error.exit_code).unwrap_or(1))
        }
    }
}
