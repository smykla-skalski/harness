// Canonical unit tests run in the root package. Clippy still constructs a
// library test target for `--all-targets` even when Cargo marks it disabled.
#![cfg(not(test))]
#![deny(unsafe_code)]
use tracing::Level;

pub mod agents;
pub mod app;
// This crate re-includes the daemon subtree without its test targets (cfg
// not(test) above), so items reached only from the root crate's tests or a
// not-yet-wired feature path read as dead here; the root crate lints them.
#[allow(dead_code, unused_imports)]
#[path = "../../../src/daemon/mod.rs"]
pub mod daemon;
#[path = "../../../src/errors/mod.rs"]
pub mod errors;
#[path = "../../../src/feature_flags.rs"]
pub mod feature_flags;
pub(crate) mod git;
#[path = "../../../src/github_api/mod.rs"]
pub(crate) mod github_api;
pub mod hooks;
pub mod infra;
pub mod kernel;
pub mod observe;
#[path = "../../../src/reviews/mod.rs"]
pub mod reviews;
pub mod run;
#[path = "../../../src/sandbox/mod.rs"]
pub mod sandbox;
pub mod session;
pub mod setup;
#[path = "../../../src/task_board/mod.rs"]
pub mod task_board;
pub mod telemetry {
    pub use harness_telemetry::*;
}
pub mod workspace;

pub const DEFAULT_LOG_LEVEL: &str = "info";
pub const DEFAULT_LOG_FILTER_DIRECTIVE: &str = "harness=info";
pub const DAEMON_ACTIVITY_LOG_LEVEL: Level = Level::DEBUG;

pub use harness_telemetry::{LogFilterHandle, log_filter_handle, set_log_filter_handle};
