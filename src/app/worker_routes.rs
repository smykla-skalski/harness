use std::ffi::OsString;

use clap::{Args, Subcommand};

/// Arguments validated by the selected worker after process delegation.
#[derive(Debug, Clone, Args)]
pub struct WorkerArgs {
    #[arg(num_args = 0.., allow_hyphen_values = true, trailing_var_arg = true)]
    pub args: Vec<OsString>,
}

/// Typed public routes delegated to `harness-daemon`.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum DaemonRoute {
    #[command(disable_help_flag = true)]
    Status(WorkerArgs),
    #[command(disable_help_flag = true)]
    Stop(WorkerArgs),
    #[command(disable_help_flag = true)]
    Restart(WorkerArgs),
    #[command(disable_help_flag = true)]
    InstallLaunchAgent(WorkerArgs),
    #[command(disable_help_flag = true)]
    RemoveLaunchAgent(WorkerArgs),
    #[command(disable_help_flag = true)]
    Doctor(WorkerArgs),
    #[command(disable_help_flag = true)]
    Snapshot(WorkerArgs),
}

/// Typed public routes delegated to `harness-bridge`.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum BridgeRoute {
    #[command(disable_help_flag = true)]
    Stop(WorkerArgs),
    #[command(disable_help_flag = true)]
    Status(WorkerArgs),
    #[command(disable_help_flag = true)]
    Reconfigure(WorkerArgs),
    #[command(disable_help_flag = true)]
    InstallLaunchAgent(WorkerArgs),
    #[command(disable_help_flag = true)]
    RemoveLaunchAgent(WorkerArgs),
}
