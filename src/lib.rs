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
