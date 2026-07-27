pub mod cli;
mod worker_routes;

#[cfg(target_os = "macos")]
use crate::sandbox::migration::run_startup_migration;

// `harness-daemon`, `harness-bridge`, and `harness-mcp` each pull in a
// `src/daemon/{transport,bridge}` or `src/mcp/transport.rs` file that keeps
// resolving `AppContext`/`Execute` through `crate::app::command_context`
// rather than a direct `harness_workspace` reference, because each facade
// crate compiles that source against its own local `AppContext`/`Execute`
// (or, for `harness-daemon`, its own `#[path]`-duplicated copy of this same
// module). Keep this re-export so the same indirection resolves correctly
// for the root crate. Only `daemon::bridge`/`daemon::transport` use it here;
// `unused_imports` fires without `bridge-runtime` or `daemon-runtime`.
#[cfg_attr(
    not(any(feature = "bridge-runtime", feature = "daemon-runtime")),
    allow(unused_imports)
)]
pub(crate) use harness_workspace::command_context;

/// Run process-start migrations shared by the root CLI and dedicated workers.
pub fn run_startup_migrations() {
    #[cfg(target_os = "macos")]
    run_startup_migration();
}
