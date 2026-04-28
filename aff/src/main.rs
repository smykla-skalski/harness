use std::process::ExitCode;

fn main() -> ExitCode {
    match aff::run() {
        Ok(code) => ExitCode::from(u8::try_from(code).unwrap_or(1)),
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(1)
        }
    }
}
