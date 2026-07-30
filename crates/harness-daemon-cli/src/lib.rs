//! `harness-daemon`'s own local command-line surface: `serve`, `dev`,
//! `status`, `identity`, `stop`, `restart`, launch-agent management, `doctor`,
//! and `snapshot`.
//!
//! The remote-daemon subcommand tree lives in `harness-daemon-remote-cli`.
//! `DaemonCommand` embeds that crate's command type for the `Remote`
//! subcommand while this crate owns local daemon lifecycle commands.

mod commands;
mod control;
#[cfg(test)]
mod tests;

pub use commands::{
    DaemonCommand, DaemonDevArgs, DaemonInstallLaunchAgentArgs, DaemonRemoveLaunchAgentArgs,
    DaemonRestartArgs, DaemonServeArgs, DaemonSnapshotArgs, DaemonStopArgs,
    HARNESS_MONITOR_APP_GROUP_ID,
};
