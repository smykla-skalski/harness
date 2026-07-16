#![deny(unsafe_code)]

use tracing::Level;

pub mod agents;
pub mod app;
#[cfg(test)]
mod codec;
pub mod create;
#[cfg_attr(not(feature = "daemon-runtime"), allow(dead_code, unused_imports))]
pub mod daemon;
pub mod errors;
#[cfg_attr(not(feature = "daemon-runtime"), allow(dead_code, unused_imports))]
pub mod feature_flags;
pub(crate) mod git;
#[cfg_attr(not(feature = "daemon-runtime"), allow(dead_code, unused_imports))]
pub(crate) mod github_api;
pub mod hooks;
pub mod infra;
pub mod kernel;
pub(crate) mod manifests;
#[cfg(feature = "mcp-runtime")]
pub use harness_mcp::mcp;
pub mod observe;
pub(crate) mod platform;
#[cfg_attr(not(feature = "daemon-runtime"), allow(dead_code, unused_imports))]
pub mod reviews;
pub mod run;
pub mod sandbox;
#[cfg_attr(not(feature = "daemon-runtime"), allow(dead_code, unused_imports))]
pub mod session;
pub mod setup;
pub(crate) mod suite_defaults;
#[cfg_attr(not(feature = "daemon-runtime"), allow(dead_code, unused_imports))]
pub mod task_board;
pub mod telemetry {
    pub use harness_telemetry::*;
}
pub mod workspace;

/// Default log level for harness runtime diagnostics.
pub const DEFAULT_LOG_LEVEL: &str = "info";

/// Default filter directive used when `RUST_LOG` is not set.
pub const DEFAULT_LOG_FILTER_DIRECTIVE: &str = "harness=info";

/// Default level for high-volume daemon activity logs such as requests and pushes.
pub const DAEMON_ACTIVITY_LOG_LEVEL: Level = Level::DEBUG;

pub use harness_telemetry::{LogFilterHandle, log_filter_handle, set_log_filter_handle};
