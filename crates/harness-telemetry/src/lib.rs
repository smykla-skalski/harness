#![deny(unsafe_code)]

use std::sync::{Mutex, OnceLock};

use tracing_subscriber::EnvFilter;
use tracing_subscriber::reload;

pub mod errors;
pub mod infra;
pub mod telemetry;
pub mod workspace;

pub use telemetry::*;

pub type LogFilterHandle = reload::Handle<EnvFilter, tracing_subscriber::Registry>;

static LOG_FILTER_HANDLE: OnceLock<LogFilterHandle> = OnceLock::new();
static PERSISTED_DAEMON_LOG_LEVEL: Mutex<Option<String>> = Mutex::new(None);

pub fn set_log_filter_handle(handle: LogFilterHandle) {
    let _ = LOG_FILTER_HANDLE.set(handle);
}

/// Return the reload handle installed by telemetry initialization.
#[must_use]
pub fn log_filter_handle() -> Option<&'static LogFilterHandle> {
    LOG_FILTER_HANDLE.get()
}

/// Resolve the worker log filter from `RUST_LOG` or the Harness default.
///
/// # Errors
/// This worker-only implementation currently has no fallible persisted source.
///
/// # Panics
/// Panics if another thread poisoned the persisted daemon log-level mutex.
pub fn resolved_log_filter_for_service(
    service: telemetry::RuntimeService,
) -> Result<EnvFilter, errors::CliError> {
    if let Ok(filter) = EnvFilter::try_from_default_env() {
        return Ok(filter);
    }
    if service == telemetry::RuntimeService::Daemon
        && let Some(level) = PERSISTED_DAEMON_LOG_LEVEL
            .lock()
            .expect("persisted daemon log-level mutex poisoned")
            .clone()
    {
        let directive = format!("harness={level}");
        return Ok(
            EnvFilter::try_new(&directive).unwrap_or_else(|_| EnvFilter::new("harness=info"))
        );
    }
    Ok(EnvFilter::new("harness=info"))
}

/// Initialize daemon telemetry with its persisted log-level overlay.
///
/// `RUST_LOG` retains precedence. The daemon file layer, OTLP providers,
/// metrics, and profiler use the same initialization path as other services.
///
/// # Errors
/// Returns an error when the persisted directive, telemetry configuration, or
/// tracing subscriber cannot be initialized.
///
/// # Panics
/// Panics if another thread poisoned the persisted log-level mutex.
pub fn init_daemon_tracing_subscriber(
    persisted_log_level: Option<&str>,
) -> Result<TelemetryGuard, errors::CliError> {
    *PERSISTED_DAEMON_LOG_LEVEL
        .lock()
        .expect("persisted daemon log-level mutex poisoned") =
        persisted_log_level.map(str::to_owned);
    init_tracing_subscriber_for(RuntimeService::Daemon)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with_persisted_level<T>(level: Option<&str>, action: impl FnOnce() -> T) -> T {
        let _guard = telemetry::telemetry_test_guard();
        let previous = PERSISTED_DAEMON_LOG_LEVEL
            .lock()
            .expect("persisted daemon log-level mutex poisoned")
            .clone();
        *PERSISTED_DAEMON_LOG_LEVEL
            .lock()
            .expect("persisted daemon log-level mutex poisoned") = level.map(str::to_owned);
        let result = action();
        *PERSISTED_DAEMON_LOG_LEVEL
            .lock()
            .expect("persisted daemon log-level mutex poisoned") = previous;
        result
    }

    #[test]
    fn daemon_filter_uses_persisted_level_when_rust_log_is_unset() {
        with_persisted_level(Some("debug"), || {
            temp_env::with_var_unset("RUST_LOG", || {
                assert_eq!(
                    resolved_log_filter_for_service(RuntimeService::Daemon)
                        .expect("daemon filter")
                        .to_string(),
                    "harness=debug"
                );
            });
        });
    }

    #[test]
    fn malformed_persisted_level_falls_back_to_info() {
        with_persisted_level(Some("not a directive"), || {
            temp_env::with_var_unset("RUST_LOG", || {
                assert_eq!(
                    resolved_log_filter_for_service(RuntimeService::Daemon)
                        .expect("daemon filter")
                        .to_string(),
                    "harness=info"
                );
            });
        });
    }

    #[test]
    fn rust_log_takes_precedence_over_persisted_level() {
        with_persisted_level(Some("debug"), || {
            temp_env::with_var("RUST_LOG", Some("harness=warn"), || {
                assert_eq!(
                    resolved_log_filter_for_service(RuntimeService::Daemon)
                        .expect("daemon filter")
                        .to_string(),
                    "harness=warn"
                );
            });
        });
    }
}
