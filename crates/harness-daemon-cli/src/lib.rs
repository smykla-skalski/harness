//! `harness-daemon`'s own local command-line surface: `serve`, `dev`,
//! `status`, `identity`, `stop`, `restart`, launch-agent management, `doctor`,
//! and `snapshot`.
//!
//! The remote-daemon subcommand tree (`DaemonRemoteCommand`) stays inside
//! `harness_daemon::daemon::transport` for now - it depends on the
//! remote-trust area, which does not yet have its own crate boundary
//! (`harness-remote-trust`, decided but not yet extracted). `DaemonCommand`
//! here still embeds it directly for the `Remote` subcommand, so this crate
//! depends on `harness-daemon` for that type the same way it does for
//! `db`/`service`/`http`/`state`.

mod commands;
mod control;
#[cfg(test)]
mod tests;

pub use commands::{
    DaemonCommand, DaemonDevArgs, DaemonInstallLaunchAgentArgs, DaemonRemoveLaunchAgentArgs,
    DaemonRestartArgs, DaemonServeArgs, DaemonSnapshotArgs, DaemonStopArgs,
    HARNESS_MONITOR_APP_GROUP_ID,
};
