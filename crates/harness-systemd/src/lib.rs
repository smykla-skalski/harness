#![deny(unsafe_code)]

pub mod app;
pub mod daemon;
pub mod errors;
pub mod workspace;

use std::ffi::OsString;

use app::command_context::{AppContext, Execute};
use clap::{Parser, Subcommand};
use daemon::transport::{
    DaemonRemoteSystemdArgs, DaemonRemoteSystemdInstallArgs, DaemonRemoteSystemdRecoverArgs,
    DaemonRemoteSystemdRollbackArgs, DaemonRemoteSystemdUpgradeArgs,
};
use errors::CliError;

/// Standalone systemd lifecycle controller.
#[derive(Debug, Parser)]
#[command(
    name = "harness-systemd",
    version,
    about = "Harness systemd lifecycle controller"
)]
pub struct Cli {
    #[command(subcommand)]
    command: SystemdCommand,
}

#[derive(Debug, Subcommand)]
enum SystemdCommand {
    /// Install a hardened remote daemon service.
    Install(DaemonRemoteSystemdInstallArgs),
    /// Transactionally upgrade the daemon and its durable state.
    Upgrade(DaemonRemoteSystemdUpgradeArgs),
    /// Restore the retained daemon and state generation.
    Rollback(DaemonRemoteSystemdRollbackArgs),
    /// Recover an interrupted lifecycle transaction.
    Recover(DaemonRemoteSystemdRecoverArgs),
    /// Remove a managed remote daemon service.
    Uninstall(DaemonRemoteSystemdArgs),
    /// Show managed service status.
    Status(DaemonRemoteSystemdArgs),
}

impl Execute for SystemdCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Install(args) => args.execute(context),
            Self::Upgrade(args) => args.execute(context),
            Self::Rollback(args) => args.execute(context),
            Self::Recover(args) => args.execute(context),
            Self::Uninstall(args) => args.uninstall(context),
            Self::Status(args) => args.status(context),
        }
    }
}

/// Parse and execute the standalone controller.
///
/// # Errors
/// Returns a lifecycle error when the selected operation fails.
pub fn run<I, T>(arguments: I) -> Result<i32, CliError>
where
    I: IntoIterator<Item = T>,
    T: Into<OsString> + Clone,
{
    let cli = Cli::parse_from(arguments);
    cli.command.execute(&AppContext)
}
