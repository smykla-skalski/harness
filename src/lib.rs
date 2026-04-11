#![deny(unsafe_code)]

use std::sync::OnceLock;

use tracing_subscriber::EnvFilter;
use tracing_subscriber::reload;

pub mod agents;
pub mod app;
#[cfg(test)]
mod codec;
pub mod create;
pub mod daemon;
pub mod errors;
pub mod hooks;
pub mod infra;
pub mod kernel;
pub(crate) mod manifests;
pub mod observe;
pub(crate) mod platform;
pub mod run;
pub mod session;
pub mod setup;
pub(crate) mod suite_defaults;
pub mod workspace;

/// Handle type for runtime log filter reloading.
pub type LogFilterHandle = reload::Handle<EnvFilter, tracing_subscriber::Registry>;

/// Default log level for harness runtime diagnostics.
pub const DEFAULT_LOG_LEVEL: &str = "trace";

/// Default filter directive used when `RUST_LOG` is not set.
pub const DEFAULT_LOG_FILTER_DIRECTIVE: &str = "harness=trace";

static LOG_FILTER_HANDLE: OnceLock<LogFilterHandle> = OnceLock::new();

/// Store the global log filter reload handle.
///
/// Called once during subscriber initialization in `main()`.
pub fn set_log_filter_handle(handle: LogFilterHandle) {
    let _ = LOG_FILTER_HANDLE.set(handle);
}

/// Access the global log filter reload handle.
///
/// Returns `None` before the tracing subscriber has been initialized.
#[must_use]
pub fn log_filter_handle() -> Option<&'static LogFilterHandle> {
    LOG_FILTER_HANDLE.get()
}

/// Build the default tracing filter used when no explicit env override exists.
#[must_use]
pub fn default_log_filter() -> EnvFilter {
    EnvFilter::new(DEFAULT_LOG_FILTER_DIRECTIVE)
}

/// Resolve the active tracing filter from `RUST_LOG`, falling back to the
/// repo default when the environment does not provide one.
#[must_use]
pub fn resolved_log_filter_from_env() -> EnvFilter {
    EnvFilter::try_from_default_env().unwrap_or_else(|_| default_log_filter())
}

#[cfg(test)]
mod logging_tests {
    use super::*;

    #[test]
    fn default_log_filter_uses_trace() {
        assert_eq!(
            default_log_filter().to_string(),
            DEFAULT_LOG_FILTER_DIRECTIVE
        );
    }

    #[test]
    fn resolved_log_filter_falls_back_to_trace_when_rust_log_is_unset() {
        temp_env::with_var_unset("RUST_LOG", || {
            assert_eq!(
                resolved_log_filter_from_env().to_string(),
                DEFAULT_LOG_FILTER_DIRECTIVE
            );
        });
    }
}
