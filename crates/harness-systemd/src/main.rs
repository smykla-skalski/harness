use std::env;
use std::process::ExitCode;

use harness_systemd::{errors::render_error, run};

fn main() -> ExitCode {
    match run(env::args_os()) {
        Ok(code) => exit_code(code),
        Err(error) => {
            eprintln!("{}", render_error(&error));
            exit_code(error.exit_code())
        }
    }
}

fn exit_code(code: i32) -> ExitCode {
    ExitCode::from(u8::try_from(code).unwrap_or(1))
}
