use std::env::current_exe;
use std::path::PathBuf;
use std::time::Duration;

use clap::{Args, Subcommand};
use tokio::runtime::Runtime;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};

use super::launchd;
use super::service::{self, DaemonServeConfig};
use super::snapshot;

/// Local daemon commands used by the macOS monitor app.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum DaemonCommand {
    /// Serve the local daemon HTTP API.
    Serve(DaemonServeArgs),
    /// Show daemon manifest and project/session counts.
    Status,
    /// Install the per-user `LaunchAgent` plist.
    InstallLaunchAgent(DaemonInstallLaunchAgentArgs),
    /// Remove the per-user `LaunchAgent` plist.
    RemoveLaunchAgent(DaemonRemoveLaunchAgentArgs),
    /// Run a local daemon diagnostics summary.
    Doctor,
    /// Print a single session snapshot for contract debugging.
    Snapshot(DaemonSnapshotArgs),
}

impl Execute for DaemonCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Serve(args) => args.execute(context),
            Self::Status => {
                let report = service::status_report()?;
                print_json(&report)?;
                Ok(0)
            }
            Self::Doctor => {
                let report = service::diagnostics_report()?;
                print_json(&report)?;
                Ok(0)
            }
            Self::InstallLaunchAgent(args) => args.execute(context),
            Self::RemoveLaunchAgent(args) => args.execute(context),
            Self::Snapshot(args) => args.execute(context),
        }
    }
}

#[derive(Debug, Clone, Args)]
pub struct DaemonServeArgs {
    /// Host interface to bind.
    #[arg(long, default_value = "127.0.0.1")]
    pub host: String,
    /// TCP port to bind. Use 0 for an ephemeral port.
    #[arg(long, default_value_t = 0)]
    pub port: u16,
    /// Periodic refresh interval in seconds.
    #[arg(long, default_value_t = 2)]
    pub refresh_seconds: u64,
    /// Poll interval in seconds for daemon-owned observe loops.
    #[arg(long, default_value_t = 5)]
    pub observe_seconds: u64,
}

impl Execute for DaemonServeArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let runtime = Runtime::new().map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "create daemon tokio runtime: {error}"
            )))
        })?;
        runtime.block_on(service::serve(DaemonServeConfig {
            host: self.host.clone(),
            port: self.port,
            poll_interval: Duration::from_secs(self.refresh_seconds.max(1)),
            observe_interval: Duration::from_secs(self.observe_seconds.max(1)),
        }))?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct DaemonInstallLaunchAgentArgs {
    /// Explicit path to the harness binary. Defaults to the current executable.
    #[arg(long)]
    pub binary_path: Option<PathBuf>,
    /// Print the full post-install `launchd` status as JSON.
    #[arg(long)]
    pub json: bool,
}

impl Execute for DaemonInstallLaunchAgentArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let binary = self
            .binary_path
            .clone()
            .map_or_else(current_exe, Ok)
            .map_err(|error| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "resolve current harness binary: {error}"
                )))
            })?;
        let path = launchd::install_launch_agent(&binary)?;
        if self.json {
            print_json(&launchd::launch_agent_status())?;
        } else {
            println!("{}", path.display());
        }
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct DaemonRemoveLaunchAgentArgs {
    /// Print the full post-remove `launchd` status as JSON.
    #[arg(long)]
    pub json: bool,
}

impl Execute for DaemonRemoveLaunchAgentArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let removed = launchd::remove_launch_agent()?;
        if self.json {
            print_json(&launchd::launch_agent_status())?;
        } else {
            println!("{}", if removed { "removed" } else { "not installed" });
        }
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct DaemonSnapshotArgs {
    /// Session ID to snapshot.
    #[arg(long)]
    pub session: String,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
}

impl Execute for DaemonSnapshotArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let detail = snapshot::session_detail(&self.session)?;
        if self.json {
            print_json(&detail)?;
        } else {
            println!(
                "{} [{}] - {}",
                detail.session.session_id, detail.session.project_name, detail.session.context,
            );
        }
        Ok(0)
    }
}

fn print_json<T: serde::Serialize>(value: &T) -> Result<(), CliError> {
    let json = serde_json::to_string_pretty(value)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    println!("{json}");
    Ok(())
}
