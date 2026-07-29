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
pub use harness_feature_flags::feature_flags;
pub(crate) mod git;
pub(crate) mod github_api {
    pub use harness_github_api::*;
}
pub mod hooks;
pub mod infra;
pub mod observe;
pub mod reviews {
    pub use harness_reviews::*;
    // These four groups sit in `harness_reviews`'s own submodules rather
    // than its crate root, unlike everything the glob above already
    // reaches; root's own `src/reviews/mod.rs` facade re-exports the same
    // four, `pub(crate)` there because only its own `daemon` module (not
    // this crate's other, unrelated modules) is meant to reach them, and
    // that constraint is identical here since only `crate::daemon` uses
    // any of these four.
    pub(crate) use harness_reviews::files::local_clone::{
        LocalCloneRegistry, LocalCloneRoot, RegistryEntry, RepoKey,
    };
    #[cfg(any(test, feature = "daemon-runtime"))]
    pub(crate) use harness_reviews::files::preview_from_patch;
    #[cfg(any(test, feature = "daemon-runtime"))]
    pub(crate) use harness_reviews::files::viewed::{ViewedMutation, classify_outcome};
    #[cfg(any(test, feature = "daemon-runtime"))]
    pub(crate) use harness_reviews::github::ReviewsGitHubClient;
}
pub use harness_workspace::sandbox;
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
