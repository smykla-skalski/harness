use std::env::current_exe;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::time::Duration;

use clap::{Args, Subcommand};
use tokio::runtime::Runtime;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::normalized_env_value;

use super::super::launchd;
use super::super::service::{self, DaemonServeConfig};
use super::super::snapshot;
use super::super::state;
use super::control::{
    adopt_daemon_root_for_transport_command, exit_code_from_status, print_daemon_control_response,
    print_json, resolve_current_exe_for, restart_daemon, stop_daemon,
};

/// Local daemon commands used by the macOS Harness app.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum DaemonCommand {
    /// Serve the local daemon HTTP API.
    Serve(DaemonServeArgs),
    /// Serve an unsandboxed dev daemon whose manifest the sandboxed Harness
    /// Monitor app can read. Thin wrapper over `serve` with dev defaults.
    Dev(DaemonDevArgs),
    /// Show daemon manifest and project/session counts.
    Status,
    /// Stop the local daemon.
    Stop(DaemonStopArgs),
    /// Restart the local daemon.
    Restart(DaemonRestartArgs),
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
            Self::Dev(args) => args.execute(context),
            Self::Status => {
                adopt_daemon_root_for_transport_command("daemon-status");
                let report = service::status_report()?;
                print_json(&report)?;
                Ok(0)
            }
            Self::Stop(args) => args.execute(context),
            Self::Restart(args) => args.execute(context),
            Self::Doctor => {
                adopt_daemon_root_for_transport_command("daemon-doctor");
                let db_path = state::daemon_root().join("harness.db");
                let db = super::super::db::DaemonDb::open(&db_path)?;
                let report = service::diagnostics_report(Some(&db))?;
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
pub struct DaemonStopArgs {
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
}

impl Execute for DaemonStopArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        adopt_daemon_root_for_transport_command("daemon-stop");
        let response = stop_daemon()?;
        print_daemon_control_response(&response, self.json)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct DaemonRestartArgs {
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
}

impl Execute for DaemonRestartArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        adopt_daemon_root_for_transport_command("daemon-restart");
        let binary = current_exe().map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "resolve current harness binary: {error}"
            )))
        })?;
        let response = restart_daemon(&binary)?;
        print_daemon_control_response(&response, self.json)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct DaemonServeArgs {
    /// Loopback host interface to bind.
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
    /// Run in macOS App Sandbox mode. Disables subprocess features (launchctl
    /// install/remove, daemon respawn) and surfaces structured errors instead.
    /// Enabled automatically when `HARNESS_SANDBOXED` is set to a truthy value
    /// (`1`, `true`, `yes`, `on`) in the environment.
    #[arg(long)]
    pub sandboxed: bool,
    /// WebSocket URL of a user-launched `codex app-server --listen ws://...`.
    /// Overrides the transport selected by sandbox mode; equivalent to
    /// setting `HARNESS_CODEX_WS_URL`. Sandboxed daemon flows require a
    /// loopback endpoint.
    #[arg(long, value_name = "URL")]
    pub codex_ws_url: Option<String>,
}

impl Execute for DaemonServeArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let runtime = Runtime::new().map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "create daemon tokio runtime: {error}"
            )))
        })?;
        let sandboxed = self.sandboxed || service::sandboxed_from_env();
        let codex_transport = match self.codex_ws_url.as_ref() {
            Some(url) if !url.trim().is_empty() => {
                super::super::codex_transport::CodexTransportKind::WebSocket {
                    endpoint: url.trim().to_string(),
                }
            }
            _ => service::codex_transport_from_env(sandboxed),
        };
        runtime.block_on(service::serve(DaemonServeConfig {
            host: self.host.clone(),
            port: self.port,
            poll_interval: Duration::from_secs(self.refresh_seconds.max(1)),
            observe_interval: Duration::from_secs(self.observe_seconds.max(1)),
            sandboxed,
            codex_transport,
        }))?;
        Ok(0)
    }
}

/// Default macOS app group identifier for the sandboxed Harness Monitor app.
/// The unsandboxed dev daemon writes its manifest into this group's container
/// so the sandboxed `SwiftUI` app can read it without extra env plumbing.
pub const HARNESS_MONITOR_APP_GROUP_ID: &str = "Q498EB36N4.io.harnessmonitor";

#[derive(Debug, Clone, Args)]
pub struct DaemonDevArgs {
    /// Host interface to bind.
    #[arg(long, default_value = "127.0.0.1")]
    pub host: String,
    /// TCP port to bind. Use 0 for an ephemeral port.
    #[arg(long, default_value_t = 0)]
    pub port: u16,
    /// macOS app group identifier used when resolving the daemon data root.
    /// Defaults to the sandboxed Harness Monitor app's group so the monitor
    /// can read the manifest written by this process.
    #[arg(long, default_value = HARNESS_MONITOR_APP_GROUP_ID)]
    pub app_group_id: String,
    /// Optional WebSocket URL of an externally-managed `codex app-server`.
    /// Leave unset to let the unsandboxed dev daemon spawn codex over stdio,
    /// which is the whole point of dev mode (no codex bridge required).
    #[arg(long, value_name = "URL")]
    pub codex_ws_url: Option<String>,
}

/// Describes how `harness daemon dev` should spawn the inner `daemon serve`
/// child. Extracted so the command wiring can be unit-tested without
/// actually spawning a process.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct DaemonDevSpawnPlan {
    pub(super) args: Vec<String>,
    pub(super) set_env: Vec<(String, String)>,
    pub(super) unset_env: Vec<String>,
    pub(super) log_effective_app_group: Option<String>,
}

impl DaemonDevArgs {
    pub(super) fn ensure_not_sandboxed() -> Result<(), CliError> {
        if service::sandboxed_from_env() {
            return Err(CliError::from(CliErrorKind::workflow_io(
                "cannot run `harness daemon dev` while HARNESS_SANDBOXED is set; \
                 unset it or use `harness daemon serve` instead",
            )));
        }
        Ok(())
    }

    pub(super) fn spawn_plan(&self) -> DaemonDevSpawnPlan {
        let mut args = vec![
            "daemon".to_string(),
            "serve".to_string(),
            "--host".to_string(),
            self.host.clone(),
            "--port".to_string(),
            self.port.to_string(),
        ];
        if let Some(url) = self.codex_ws_url.as_deref().map(str::trim)
            && !url.is_empty()
        {
            args.push("--codex-ws-url".to_string());
            args.push(url.to_string());
        }

        let mut set_env = Vec::new();
        let mut log_effective_app_group = None;
        if normalized_env_value(state::APP_GROUP_ID_ENV).is_none() {
            set_env.push((
                "HARNESS_APP_GROUP_ID".to_string(),
                self.app_group_id.clone(),
            ));
            log_effective_app_group = Some(self.app_group_id.clone());
        }

        DaemonDevSpawnPlan {
            args,
            set_env,
            unset_env: vec!["HARNESS_SANDBOXED".to_string()],
            log_effective_app_group,
        }
    }
}

impl Execute for DaemonDevArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        Self::ensure_not_sandboxed()?;
        let binary = resolve_current_exe_for("dev daemon")?;
        let plan = self.spawn_plan();
        plan.log_effective_app_group();
        let status = plan.spawn(&binary)?;
        Ok(exit_code_from_status(status))
    }
}

impl DaemonDevSpawnPlan {
    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion; tokio-rs/tracing#553"
    )]
    fn log_effective_app_group(&self) {
        let Some(app_group) = self.log_effective_app_group.as_deref() else {
            return;
        };
        tracing::info!(
            app_group_id = %app_group,
            "daemon dev: defaulted HARNESS_APP_GROUP_ID so sandboxed monitor app can read the manifest",
        );
    }

    fn spawn(&self, binary: &Path) -> Result<ExitStatus, CliError> {
        let mut command = Command::new(binary);
        command.args(&self.args);
        for (key, value) in &self.set_env {
            command.env(key, value);
        }
        for key in &self.unset_env {
            command.env_remove(key);
        }
        command
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());

        command.status().map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "spawn harness daemon serve for dev daemon: {error}"
            )))
        })
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
        let path = launchd::install_launch_agent(service::sandboxed_from_env(), &binary)?;
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
        let removed = launchd::remove_launch_agent(service::sandboxed_from_env())?;
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
        adopt_daemon_root_for_transport_command("daemon-snapshot");
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
