use std::env::current_exe;
use std::path::PathBuf;
use std::time::Duration;

use clap::{Args, Subcommand};
use tokio::runtime::Runtime;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::feature_flags;
use crate::workspace::{host_home_dir, normalized_env_value};

use super::super::launchd;
use super::super::service::{self, DaemonServeConfig};
use super::super::snapshot;
use super::super::state;
use super::control::{
    adopt_daemon_root_for_transport_command, print_daemon_control_response, print_json,
    restart_daemon, stop_daemon,
};
use super::remote::DaemonRemoteCommand;
use super::remote_systemd::{ensure_linux_systemd, systemd_daemon_root};

/// Local daemon operations and remote-daemon scaffolding.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum DaemonCommand {
    /// Serve the local daemon HTTP API.
    Serve(DaemonServeArgs),
    /// Serve an unsandboxed dev daemon whose manifest the sandboxed Harness
    /// Monitor app can read. Thin wrapper over `serve` with dev defaults.
    Dev(DaemonDevArgs),
    /// Serve and manage an internet-reachable remote daemon.
    Remote {
        /// Use the private state directory of an installed systemd unit.
        #[arg(long, global = true)]
        systemd_unit: Option<String>,
        #[command(subcommand)]
        command: DaemonRemoteCommand,
    },
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
            Self::Remote {
                command,
                systemd_unit,
            } => execute_remote_command(command, systemd_unit.as_deref(), context),
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

fn execute_remote_command(
    command: &DaemonRemoteCommand,
    systemd_unit: Option<&str>,
    context: &AppContext,
) -> Result<i32, CliError> {
    let _root_override = systemd_unit
        .map(|unit| {
            ensure_linux_systemd()?;
            systemd_daemon_root(unit)
        })
        .transpose()?
        .map(|root| state::ScopedDaemonRootOverride::set(Some(root)));
    command.execute(context)
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
    /// Enable ACP managed-agent routes for this daemon process.
    #[arg(long, conflicts_with = "disable_acp")]
    pub enable_acp: bool,
    /// Disable ACP managed-agent routes for this daemon process without
    /// mutating the caller's `HARNESS_FEATURE_ACP` shell environment.
    #[arg(long, conflicts_with = "enable_acp")]
    pub disable_acp: bool,
}

impl Execute for DaemonServeArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        execute_daemon_service(self.serve_config(), self.acp_enabled_override(), None)
    }
}

impl DaemonServeArgs {
    #[must_use]
    pub(super) const fn acp_enabled_override(&self) -> Option<bool> {
        if self.enable_acp {
            Some(true)
        } else if self.disable_acp {
            Some(false)
        } else {
            None
        }
    }

    fn serve_config(&self) -> DaemonServeConfig {
        let sandboxed = self.sandboxed || service::sandboxed_from_env();
        let codex_transport = match self.codex_ws_url.as_ref() {
            Some(url) if !url.trim().is_empty() => {
                super::super::codex_transport::CodexTransportKind::WebSocket {
                    endpoint: url.trim().to_string(),
                }
            }
            _ => service::codex_transport_from_env(sandboxed),
        };
        DaemonServeConfig {
            host: self.host.clone(),
            port: self.port,
            auth_mode: super::super::http::DaemonHttpAuthMode::Local,
            remote_domain: None,
            poll_interval: Duration::from_secs(self.refresh_seconds.max(1)),
            observe_interval: Duration::from_secs(self.observe_seconds.max(1)),
            sandboxed,
            codex_transport,
        }
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
    /// Enable ACP managed-agent routes for the dev daemon.
    #[arg(long, conflicts_with = "disable_acp")]
    pub enable_acp: bool,
    /// Disable ACP managed-agent routes for the dev daemon.
    #[arg(long, conflicts_with = "enable_acp")]
    pub disable_acp: bool,
}

/// Describes how `harness daemon dev` resolves its in-process daemon runtime.
#[derive(Debug, Clone)]
pub(super) struct DaemonDevExecutionPlan {
    pub(super) daemon_root_base: PathBuf,
    pub(super) daemon_root: PathBuf,
    pub(super) serve_config: DaemonServeConfig,
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

    pub(super) fn execution_plan(&self) -> DaemonDevExecutionPlan {
        let mut log_effective_app_group = None;
        if normalized_env_value(state::APP_GROUP_ID_ENV).is_none() {
            log_effective_app_group = Some(self.app_group_id.clone());
        }

        let daemon_root_base =
            if let Some(value) = normalized_env_value(state::DAEMON_DATA_HOME_ENV) {
                PathBuf::from(value).join("harness").join("daemon")
            } else {
                let effective_app_group = normalized_env_value(state::APP_GROUP_ID_ENV)
                    .unwrap_or_else(|| self.app_group_id.clone());
                host_home_dir()
                    .join("Library")
                    .join("Group Containers")
                    .join(effective_app_group)
                    .join("harness")
                    .join("daemon")
            };
        let daemon_root = daemon_root_base.join(state::DaemonOwnership::External.as_str());

        let codex_transport = match self.codex_ws_url.as_deref().map(str::trim) {
            Some(url) if !url.is_empty() => {
                super::super::codex_transport::CodexTransportKind::WebSocket {
                    endpoint: url.to_string(),
                }
            }
            _ => service::codex_transport_from_env(false),
        };

        DaemonDevExecutionPlan {
            daemon_root_base,
            daemon_root,
            serve_config: DaemonServeConfig {
                host: self.host.clone(),
                port: self.port,
                auth_mode: super::super::http::DaemonHttpAuthMode::Local,
                remote_domain: None,
                poll_interval: Duration::from_secs(2),
                observe_interval: Duration::from_secs(5),
                sandboxed: false,
                codex_transport,
            },
            log_effective_app_group,
        }
    }
}

impl DaemonDevArgs {
    #[must_use]
    pub(super) const fn acp_enabled_override(&self) -> Option<bool> {
        if self.enable_acp {
            Some(true)
        } else if self.disable_acp {
            Some(false)
        } else {
            None
        }
    }
}

impl Execute for DaemonDevArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        Self::ensure_not_sandboxed()?;
        let plan = self.execution_plan();
        plan.log_effective_app_group();
        let _ownership_override =
            state::ScopedOwnershipOverride::set(Some(state::DaemonOwnership::External));
        let migration = state::migrate_legacy_daemon_root_at(
            &plan.daemon_root_base,
            &plan.daemon_root,
            state::DaemonOwnership::External,
        )?;
        log_dev_legacy_daemon_root_migration(&migration);
        execute_daemon_service(
            plan.serve_config,
            self.acp_enabled_override(),
            Some(plan.daemon_root),
        )
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_dev_legacy_daemon_root_migration(report: &state::LegacyDaemonRootMigration) {
    use state::MigrationDecision;
    match &report.decision {
        MigrationDecision::Migrated { count } => {
            tracing::info!(
                from = %report.from.display(),
                to = %report.to.display(),
                entries = count,
                "daemon dev: migrated legacy daemon state into external ownership subtree"
            );
        }
        MigrationDecision::OwnershipMismatch { inferred, current } => {
            tracing::info!(
                from = %report.from.display(),
                inferred = %inferred,
                current = %current,
                "daemon dev: legacy state owned by other side; sibling daemon will migrate it"
            );
        }
        MigrationDecision::LegacyDaemonAlive => {
            tracing::warn!(
                from = %report.from.display(),
                "daemon dev: legacy daemon still running; skipping migration"
            );
        }
        MigrationDecision::UnreadableLegacyManifest => {
            tracing::warn!(
                from = %report.from.display(),
                "daemon dev: legacy manifest is unreadable; skipping migration"
            );
        }
        MigrationDecision::AlreadyMigrated | MigrationDecision::NoLegacyState => {}
    }
}

impl DaemonDevExecutionPlan {
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
}

fn execute_daemon_service(
    config: DaemonServeConfig,
    acp_enabled_override: Option<bool>,
    daemon_root_override: Option<PathBuf>,
) -> Result<i32, CliError> {
    let _acp_override = feature_flags::scoped_acp_enabled_override(acp_enabled_override);
    let _daemon_root_override = state::ScopedDaemonRootOverride::set(daemon_root_override);
    let runtime = Runtime::new().map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "create daemon tokio runtime: {error}"
        )))
    })?;
    runtime.block_on(service::serve(config))?;
    Ok(0)
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
