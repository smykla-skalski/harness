use std::process::ExitCode;
use std::thread;
use std::time::Duration;

use clap::Parser;
use harness_daemon::app::{AppContext, Execute};
use harness_daemon::daemon::{state, transport::DaemonCommand};
use harness_daemon::errors;
use harness_telemetry::init_daemon_tracing_subscriber;
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(name = "harness-daemon", version, about = "Harness daemon")]
struct Cli {
    /// Seconds to wait before executing the command.
    #[arg(long, default_value = "0", global = true)]
    delay: f64,
    #[command(subcommand)]
    command: DaemonCommand,
}

fn main() -> ExitCode {
    if let Some(result) = delegate_systemd_lifecycle() {
        return match result {
            Ok(code) => exit_code(code),
            Err(error) => render_error(&error),
        };
    }
    let (persisted_log_level, persisted_log_error) = startup_persisted_log_level();
    let telemetry_guard = match init_daemon_tracing_subscriber(persisted_log_level.as_deref()) {
        Ok(guard) => guard,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::FAILURE;
        }
    };
    if let Some(error) = persisted_log_error {
        state::append_event_best_effort("warn", &persisted_log_warning(&error));
    }
    let cli = Cli::parse();
    if cli.delay > 0.0 {
        thread::sleep(Duration::from_secs_f64(cli.delay));
    }
    harness_daemon::app::run_startup_migrations();
    let result = cli.command.execute(&AppContext::production());
    drop(telemetry_guard);
    match result {
        Ok(code) => exit_code(code),
        Err(error) => render_error(&error),
    }
}

fn delegate_systemd_lifecycle() -> Option<Result<i32, errors::CliError>> {
    let arguments = harness_command::routed_args("remote").ok()?;
    let mut arguments = match strip_daemon_only_globals(arguments) {
        Ok(arguments) => arguments,
        Err(error) => return Some(Err(error)),
    };
    let command = arguments.first()?.to_str()?;
    let direct = match command {
        "install-systemd" => "install",
        "upgrade-systemd" => "upgrade",
        "rollback-systemd" => "rollback",
        "recover-systemd" => "recover",
        "uninstall-systemd" => "uninstall",
        "status" => "status",
        _ => return None,
    };
    arguments[0] = direct.into();
    Some(
        harness_command::exec_trusted_worker(
            "harness-systemd",
            env!("CARGO_PKG_VERSION"),
            arguments,
        )
        .map_err(|error| worker_error(&error)),
    )
}

fn strip_daemon_only_globals(
    arguments: Vec<std::ffi::OsString>,
) -> Result<Vec<std::ffi::OsString>, errors::CliError> {
    let mut arguments = arguments.into_iter();
    let mut direct = Vec::new();
    let mut options_ended = false;
    while let Some(argument) = arguments.next() {
        if options_ended {
            direct.push(argument);
        } else if argument == "--" {
            options_ended = true;
            direct.push(argument);
        } else if argument == "--systemd-unit" {
            arguments.next().ok_or_else(|| {
                errors::CliError::from(errors::CliErrorKind::workflow_parse(
                    "missing value for daemon --systemd-unit while delegating lifecycle command"
                        .to_string(),
                ))
            })?;
        } else if !argument
            .to_str()
            .is_some_and(|value| value.starts_with("--systemd-unit="))
        {
            direct.push(argument);
        }
    }
    Ok(direct)
}

fn worker_error(error: &harness_command::WorkerError) -> errors::CliError {
    errors::CliErrorKind::workflow_io(error.to_string()).into()
}

fn startup_persisted_log_level() -> (Option<String>, Option<errors::CliError>) {
    if EnvFilter::try_from_default_env().is_ok() {
        return (None, None);
    }
    match state::load_persisted_log_level() {
        Ok(level) => (level, None),
        Err(error) => (None, Some(error)),
    }
}

fn persisted_log_warning(error: &errors::CliError) -> String {
    format!(
        "ignored persisted daemon log config {}; using {}: {error}",
        state::config_path().display(),
        harness_daemon::DEFAULT_LOG_FILTER_DIRECTIVE
    )
}

fn render_error(error: &errors::CliError) -> ExitCode {
    eprintln!("{}", errors::render_error(error));
    exit_code(error.exit_code())
}

fn exit_code(code: i32) -> ExitCode {
    ExitCode::from(u8::try_from(code).unwrap_or(1))
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use harness_daemon::daemon::state::ScopedDaemonRootOverride;

    use super::*;

    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn with_malformed_persisted_config(action: impl FnOnce()) {
        let _lock = TEST_LOCK.lock().expect("test lock");
        let temporary = tempfile::tempdir().expect("temporary directory");
        let _root = ScopedDaemonRootOverride::set(Some(temporary.path().to_path_buf()));
        fs_err::write(state::config_path(), "not valid JSON").expect("write malformed config");
        action();
    }

    #[test]
    fn valid_rust_log_does_not_consult_malformed_persisted_config() {
        with_malformed_persisted_config(|| {
            temp_env::with_var("RUST_LOG", Some("harness=trace"), || {
                let (level, error) = startup_persisted_log_level();
                assert_eq!(level, None);
                assert!(error.is_none());
            });
        });
    }

    #[test]
    fn invalid_rust_log_uses_persisted_fallback_and_reports_malformed_config() {
        with_malformed_persisted_config(|| {
            temp_env::with_var("RUST_LOG", Some("[invalid"), || {
                let (level, error) = startup_persisted_log_level();
                assert_eq!(level, None);
                let warning = persisted_log_warning(&error.expect("persisted config error"));
                assert!(warning.contains(&state::config_path().display().to_string()));
                assert!(warning.contains(harness_daemon::DEFAULT_LOG_FILTER_DIRECTIVE));
            });
        });
    }

    #[test]
    fn absent_rust_log_uses_persisted_fallback_and_reports_malformed_config() {
        with_malformed_persisted_config(|| {
            temp_env::with_var_unset("RUST_LOG", || {
                let (level, error) = startup_persisted_log_level();
                assert_eq!(level, None);
                let warning = persisted_log_warning(&error.expect("persisted config error"));
                assert!(warning.contains(&state::config_path().display().to_string()));
                assert!(warning.contains(harness_daemon::DEFAULT_LOG_FILTER_DIRECTIVE));
            });
        });
    }
}
