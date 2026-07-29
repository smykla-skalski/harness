pub mod cli;
mod worker_routes;

#[cfg(target_os = "macos")]
use crate::sandbox::migration::run_startup_migration;

// `harness-daemon` `#[path]`-includes the whole `daemon::bridge` and
// `daemon::transport` trees as its own compilation, alongside its own
// `#[path]`-duplicated copy of `command_context.rs` (see
// `crates/harness-daemon/src/app.rs`). Those two trees, both gated behind
// `daemon-runtime`, keep resolving `AppContext`/`Execute` through
// `crate::app::command_context` rather than a direct `harness_workspace`
// reference so that, inside `harness-daemon`'s build, they agree with each
// other and with `harness-daemon`'s own `main.rs` on one nominal
// `AppContext`/`Execute` identity instead of silently splitting into two
// same-name, different-type copies. Keep this re-export so the same
// indirection resolves correctly for the root crate too. `task_board::transport`
// used to need this same indirection for the same reason, until
// `harness-daemon` stopped `#[path]`-including the whole `task_board` tree;
// it now imports `harness_workspace::command_context` directly, so this
// re-export narrows to the two trees that still need it.
#[cfg(feature = "daemon-runtime")]
pub(crate) use harness_workspace::command_context;

/// Run process-start migrations shared by the root CLI and dedicated workers.
pub fn run_startup_migrations() {
    #[cfg(target_os = "macos")]
    run_startup_migration();
}
