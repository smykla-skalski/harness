use std::env::current_exe;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::LazyLock;
use std::thread;
use std::time::{Duration, Instant};

use clap::{Args, Subcommand};
use tokio::runtime::Runtime;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::exec::RUNTIME;

use super::launchd;
use super::protocol::DaemonControlResponse;
use super::service::{self, DaemonServeConfig};
use super::snapshot;

const DAEMON_CONTROL_TIMEOUT: Duration = Duration::from_secs(8);
const DAEMON_CONTROL_POLL_INTERVAL: Duration = Duration::from_millis(250);
const DAEMON_HTTP_TIMEOUT: Duration = Duration::from_secs(2);

static DAEMON_HTTP_CLIENT: LazyLock<reqwest::Client> = LazyLock::new(reqwest::Client::new);

/// Local daemon commands used by the macOS Harness app.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum DaemonCommand {
    /// Serve the local daemon HTTP API.
    Serve(DaemonServeArgs),
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
            Self::Status => {
                let report = service::status_report()?;
                print_json(&report)?;
                Ok(0)
            }
            Self::Stop(args) => args.execute(context),
            Self::Restart(args) => args.execute(context),
            Self::Doctor => {
                let db_path = super::state::daemon_root().join("harness.db");
                let db = super::db::DaemonDb::open(&db_path).ok();
                let report = service::diagnostics_report(db.as_ref())?;
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

fn stop_daemon() -> Result<DaemonControlResponse, CliError> {
    let launch_agent = launchd::launch_agent_status();
    if cfg!(target_os = "macos") && (launch_agent.installed || launch_agent.loaded) {
        let manifest = super::state::load_manifest()?;
        let booted_out = launchd::bootout_launch_agent()?;
        if booted_out && let Some(manifest) = manifest.as_ref() {
            wait_for_daemon_shutdown(&manifest.endpoint)?;
        }
    }

    let _ = request_shutdown_if_running()?;
    Ok(DaemonControlResponse {
        status: "stopped".into(),
    })
}

fn restart_daemon(binary: &Path) -> Result<DaemonControlResponse, CliError> {
    let launch_agent = launchd::launch_agent_status();
    if cfg!(target_os = "macos") && launch_agent.loaded {
        let manifest = super::state::load_manifest()?;
        let booted_out = launchd::bootout_launch_agent()?;
        if booted_out && let Some(manifest) = manifest.as_ref() {
            wait_for_daemon_shutdown(&manifest.endpoint)?;
        }
    }

    let _ = request_shutdown_if_running()?;

    if cfg!(target_os = "macos") && launch_agent.installed {
        launchd::restart_launch_agent()?;
        let _ = wait_for_healthy_daemon(None)?;
    } else {
        let mut child = spawn_daemon(binary)?;
        let _ = wait_for_healthy_daemon(Some(&mut child))?;
    }

    Ok(DaemonControlResponse {
        status: "restarted".into(),
    })
}

fn request_shutdown_if_running() -> Result<bool, CliError> {
    let Some(manifest) = super::state::load_manifest()? else {
        return Ok(false);
    };
    if !daemon_is_healthy(&manifest.endpoint) {
        return Ok(false);
    }

    let token = fs_err::read_to_string(&manifest.token_path)
        .map(|value| value.trim().to_string())
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "read daemon token {}: {error}",
                manifest.token_path
            )))
        })?;

    match post_stop_request(&manifest.endpoint, &token) {
        Ok(()) => {
            wait_for_daemon_shutdown(&manifest.endpoint)?;
            Ok(true)
        }
        Err(_error) if !daemon_is_healthy(&manifest.endpoint) => {
            wait_for_daemon_shutdown(&manifest.endpoint)?;
            Ok(true)
        }
        Err(error) => Err(error),
    }
}

fn post_stop_request(endpoint: &str, token: &str) -> Result<(), CliError> {
    let url = daemon_url(endpoint, "/v1/daemon/stop");
    let (status, body) = RUNTIME.block_on(async {
        let response = DAEMON_HTTP_CLIENT
            .post(&url)
            .bearer_auth(token)
            .json(&serde_json::json!({}))
            .timeout(DAEMON_HTTP_TIMEOUT)
            .send()
            .await
            .map_err(|error| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "request daemon stop {url}: {error}"
                )))
            })?;
        let status = response.status();
        let body = response.text().await.map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "read daemon stop response {url}: {error}"
            )))
        })?;
        Ok::<_, CliError>((status, body))
    })?;

    if !status.is_success() {
        let detail = if body.trim().is_empty() {
            format!("HTTP {status}")
        } else {
            format!("HTTP {status}: {}", body.trim())
        };
        return Err(CliError::from(CliErrorKind::workflow_io(format!(
            "request daemon stop {url}: {detail}"
        ))));
    }

    let _response: DaemonControlResponse = serde_json::from_str(&body).map_err(|error| {
        CliError::from(CliErrorKind::workflow_parse(format!(
            "parse daemon stop response {url}: {error}"
        )))
    })?;
    Ok(())
}

fn wait_for_daemon_shutdown(endpoint: &str) -> Result<(), CliError> {
    wait_for_flag(&format!("wait for daemon shutdown at {endpoint}"), || {
        let manifest_cleared = match super::state::load_manifest()? {
            Some(manifest) => manifest.endpoint != endpoint,
            None => true,
        };
        Ok(!daemon_is_healthy(endpoint) && manifest_cleared)
    })
}

fn wait_for_healthy_daemon(mut child: Option<&mut Child>) -> Result<String, CliError> {
    wait_for_value("wait for daemon health", || {
        if let Some(child) = child.as_deref_mut()
            && let Some(status) = child.try_wait().map_err(|error| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "wait for daemon child process: {error}"
                )))
            })?
        {
            return Err(CliError::from(CliErrorKind::workflow_io(format!(
                "daemon process exited before becoming healthy: {status}"
            ))));
        }

        let Some(manifest) = super::state::load_manifest()? else {
            return Ok(None);
        };
        if daemon_is_healthy(&manifest.endpoint) {
            return Ok(Some(manifest.endpoint));
        }
        Ok(None)
    })
}

fn wait_for_flag(
    label: &str,
    mut condition: impl FnMut() -> Result<bool, CliError>,
) -> Result<(), CliError> {
    let start = Instant::now();
    loop {
        if condition()? {
            return Ok(());
        }
        if start.elapsed() >= DAEMON_CONTROL_TIMEOUT {
            return Err(CliError::from(CliErrorKind::workflow_io(format!(
                "{label} timed out after {}s",
                DAEMON_CONTROL_TIMEOUT.as_secs()
            ))));
        }
        thread::sleep(DAEMON_CONTROL_POLL_INTERVAL);
    }
}

fn wait_for_value(
    label: &str,
    mut condition: impl FnMut() -> Result<Option<String>, CliError>,
) -> Result<String, CliError> {
    let start = Instant::now();
    loop {
        if let Some(value) = condition()? {
            return Ok(value);
        }
        if start.elapsed() >= DAEMON_CONTROL_TIMEOUT {
            return Err(CliError::from(CliErrorKind::workflow_io(format!(
                "{label} timed out after {}s",
                DAEMON_CONTROL_TIMEOUT.as_secs()
            ))));
        }
        thread::sleep(DAEMON_CONTROL_POLL_INTERVAL);
    }
}

fn daemon_is_healthy(endpoint: &str) -> bool {
    let url = daemon_url(endpoint, "/v1/health");
    RUNTIME.block_on(async {
        DAEMON_HTTP_CLIENT
            .get(&url)
            .timeout(DAEMON_HTTP_TIMEOUT)
            .send()
            .await
            .is_ok_and(|response| response.status().is_success())
    })
}

fn daemon_url(endpoint: &str, path: &str) -> String {
    format!("{}{path}", endpoint.trim_end_matches('/'))
}

fn spawn_daemon(binary: &Path) -> Result<Child, CliError> {
    Command::new(binary)
        .args(["daemon", "serve", "--host", "127.0.0.1", "--port", "0"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "spawn daemon process {}: {error}",
                binary.display()
            )))
        })
}

fn print_daemon_control_response(
    response: &DaemonControlResponse,
    json: bool,
) -> Result<(), CliError> {
    if json {
        print_json(response)
    } else {
        println!("{}", response.status);
        Ok(())
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
