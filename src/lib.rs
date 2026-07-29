#![deny(unsafe_code)]

use tracing::Level;

// Deliberate public API facade, not scaffolding: `harness::agents::policy`,
// `runtime`, `service`, `storage`, `kind`, and `acp` stay stable paths for
// their existing callers across session, daemon, hooks, and observe.
pub mod agents {
    pub use harness_agents::*;
}
pub mod app;
#[cfg_attr(not(feature = "daemon-runtime"), allow(dead_code, unused_imports))]
pub mod daemon;
// Deliberate public API facade, not scaffolding: `harness::errors`,
// `harness::kernel`, `harness::workspace`, `harness::sandbox` and
// `harness::feature_flags` stay stable paths for consumers of this crate.
// Code inside the workspace names `harness_kernel::`, `harness_workspace::`
// and `harness_feature_flags::` directly, so do not add uses of
// `crate::errors`, `crate::kernel`, `crate::workspace`, `crate::sandbox`,
// `crate::git` or `crate::feature_flags` on the strength of these.
#[cfg_attr(not(feature = "daemon-runtime"), allow(dead_code, unused_imports))]
pub use harness_feature_flags::feature_flags;
pub use harness_kernel::errors;
#[cfg_attr(not(feature = "daemon-runtime"), allow(dead_code, unused_imports))]
pub(crate) use harness_workspace::git;
#[cfg_attr(not(feature = "daemon-runtime"), allow(dead_code, unused_imports))]
pub(crate) mod github_api {
    pub use harness_github_api::*;
}
// Deliberate public API facade, not scaffolding: `harness::hooks` stays a
// stable path for its existing callers across setup, daemon, and observe.
pub mod hooks {
    pub use harness_hooks::*;
}
pub mod infra {
    pub use harness_infra::*;
}
pub use harness_kernel::kernel;
#[cfg(feature = "mcp-runtime")]
pub use harness_mcp::mcp;
pub mod observe;
#[cfg_attr(not(feature = "daemon-runtime"), allow(dead_code, unused_imports))]
pub mod reviews;
pub mod run {
    pub use harness_run::*;
}
pub use harness_workspace::sandbox;
#[cfg_attr(not(feature = "daemon-runtime"), allow(dead_code, unused_imports))]
pub mod session;
pub mod setup;
#[cfg_attr(not(feature = "daemon-runtime"), allow(dead_code, unused_imports))]
pub mod task_board;
pub mod telemetry {
    pub use harness_telemetry::*;
}
pub use harness_workspace::workspace;

/// Default log level for harness runtime diagnostics.
pub const DEFAULT_LOG_LEVEL: &str = "info";

/// Default filter directive used when `RUST_LOG` is not set.
pub const DEFAULT_LOG_FILTER_DIRECTIVE: &str = "harness=info";

/// Default level for high-volume daemon activity logs such as requests and pushes.
pub const DAEMON_ACTIVITY_LOG_LEVEL: Level = Level::DEBUG;

pub use harness_telemetry::{LogFilterHandle, log_filter_handle, set_log_filter_handle};
