#![deny(unsafe_code)]
// This crate's own `--lib` test target compiled to nothing until it started
// running its own tests directly, so the test tree has never been through a
// pedantic pass; running it for real surfaces a large pile of pre-existing,
// test-only findings (mostly unboxed futures in async test fixtures and
// style complaints clippy's default set adds on top of pedantic) that are
// about test-code shape, not defects. Production code keeps the full,
// undiminished lint set; this scoping applies to `cfg(test)` only.
#![cfg_attr(
    test,
    allow(
        clippy::pedantic,
        clippy::await_holding_lock,
        clippy::bool_assert_comparison,
        clippy::cloned_ref_to_slice_refs,
        clippy::explicit_auto_deref,
        clippy::field_reassign_with_default,
        clippy::manual_async_fn,
        clippy::needless_borrow,
        clippy::needless_borrows_for_generic_args,
        clippy::obfuscated_if_else,
        clippy::ok_expect,
        clippy::ptr_arg,
        clippy::redundant_locals,
        clippy::type_complexity,
        clippy::unnecessary_get_then_check,
        clippy::useless_conversion
    )
)]
use tracing::Level;

pub mod agents;
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
pub mod app;
pub mod daemon;
pub use harness_feature_flags::feature_flags;
pub use harness_kernel::errors;
#[cfg(feature = "daemon-runtime")]
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
#[cfg(feature = "daemon-runtime")]
pub mod timeline;
pub mod workspace;

pub const DEFAULT_LOG_LEVEL: &str = "info";
pub const DEFAULT_LOG_FILTER_DIRECTIVE: &str = "harness=info";
pub const DAEMON_ACTIVITY_LOG_LEVEL: Level = Level::DEBUG;

pub use harness_telemetry::{LogFilterHandle, log_filter_handle, set_log_filter_handle};
