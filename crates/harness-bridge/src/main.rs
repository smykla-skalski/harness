use std::process::ExitCode;
use std::thread;
use std::time::Duration;

use clap::Parser;
// `BridgeCommand`'s `Execute` impl binds to whichever `command_context`
// copy compiled alongside it: this crate's own under the default,
// mirror-backed build, or the real `harness-daemon`'s under
// `daemon-runtime` (see `src/daemon/mod.rs`'s `bridge` swap). Bringing in
// the wrong trait compiles clean but leaves `execute()` unresolved.
#[cfg(not(feature = "daemon-runtime"))]
use harness_bridge::app::{AppContext, Execute};
use harness_bridge::cli::Cli;
#[cfg(feature = "daemon-runtime")]
use harness_daemon::app::{AppContext, Execute};
use harness_kernel::errors;
use harness_telemetry::{
    RuntimeService, init_tracing_subscriber_for, write_runtime_fallback_error,
};

fn main() -> ExitCode {
    let cli = Cli::parse();
    cli.command.prepare_runtime_context();
    let telemetry_guard = match init_tracing_subscriber_for(RuntimeService::Bridge) {
        Ok(guard) => guard,
        Err(error) => {
            let rendered = error.to_string();
            let _ = write_runtime_fallback_error(RuntimeService::Bridge, &rendered);
            eprintln!("{rendered}");
            return ExitCode::FAILURE;
        }
    };
    if cli.delay > 0.0 {
        thread::sleep(Duration::from_secs_f64(cli.delay));
    }
    harness_bridge::app::run_startup_migrations();
    let result = cli.command.execute(&AppContext::production());
    if let Err(error) = &result {
        tracing::error!(code = error.code(), "{}", errors::render_error(error));
    }
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
