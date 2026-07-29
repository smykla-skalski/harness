// Canonical unit tests run in the root package. Clippy still constructs a
// library test target for `--all-targets` even when Cargo marks it disabled.
#![cfg(not(test))]
#![deny(unsafe_code)]
use tracing::Level;

pub mod agents;
pub mod app;
pub mod daemon;
pub use harness_feature_flags::feature_flags;
pub(crate) mod git;
pub(crate) mod github_api {
    pub use harness_github_api::*;
}
pub mod hooks;
pub mod infra;
pub mod observe;
pub mod reviews;
pub use harness_workspace::sandbox;
pub mod session;
pub mod setup;
pub mod task_board;
pub mod telemetry {
    pub use harness_telemetry::*;
}
pub mod workspace;

pub const DEFAULT_LOG_LEVEL: &str = "info";
pub const DEFAULT_LOG_FILTER_DIRECTIVE: &str = "harness=info";
pub const DAEMON_ACTIVITY_LOG_LEVEL: Level = Level::DEBUG;

pub use harness_telemetry::{LogFilterHandle, log_filter_handle, set_log_filter_handle};
