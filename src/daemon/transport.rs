use std::env::current_exe;
use std::fs;
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
use super::state;

const DAEMON_CONTROL_TIMEOUT: Duration = Duration::from_secs(15);
const DAEMON_CONTROL_POLL_INTERVAL: Duration = Duration::from_millis(50);
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
                let db_path = state::daemon_root().join("harness.db");
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
    /// Run in macOS App Sandbox mode. Disables subprocess features (launchctl
    /// install/remove, daemon respawn) and surfaces structured errors instead.
    /// Enabled automatically when `HARNESS_SANDBOXED` is set to a truthy value
    /// (`1`, `true`, `yes`, `on`) in the environment.
    #[arg(long)]
    pub sandboxed: bool,
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
            sandboxed: self.sandboxed || service::sandboxed_from_env(),
        }))?;
        Ok(0)
    }
}

fn stop_daemon() -> Result<DaemonControlResponse, CliError> {
    let launch_agent = launchd::launch_agent_status();
    let sandboxed = service::sandboxed_from_env();
    stop_daemon_with(
        cfg!(target_os = "macos"),
        &launch_agent,
        try_load_manifest,
        || launchd::bootout_launch_agent(sandboxed),
        request_shutdown_if_running,
        wait_for_daemon_shutdown,
    )
}

fn stop_daemon_with<LoadManifest, Bootout, RequestShutdown, WaitShutdown>(
    launchd_enabled: bool,
    launch_agent: &launchd::LaunchAgentStatus,
    mut load_manifest: LoadManifest,
    mut bootout: Bootout,
    mut request_shutdown: RequestShutdown,
    mut wait_for_shutdown: WaitShutdown,
) -> Result<DaemonControlResponse, CliError>
where
    LoadManifest: FnMut() -> Result<Option<super::state::DaemonManifest>, CliError>,
    Bootout: FnMut() -> Result<bool, CliError>,
    RequestShutdown: FnMut() -> Result<bool, CliError>,
    WaitShutdown: FnMut(&str) -> Result<(), CliError>,
{
    if launchd_enabled && (launch_agent.installed || launch_agent.loaded) {
        let manifest = load_manifest()?;
        let booted_out = bootout()?;
        if booted_out && let Some(manifest) = manifest.as_ref() {
            wait_for_shutdown(&manifest.endpoint)?;
        }
    }

    let _ = request_shutdown()?;
    Ok(DaemonControlResponse {
        status: "stopped".into(),
    })
}

fn restart_daemon(binary: &Path) -> Result<DaemonControlResponse, CliError> {
    let launch_agent = launchd::launch_agent_status();
    let sandboxed = service::sandboxed_from_env();
    restart_daemon_with(
        cfg!(target_os = "macos"),
        &launch_agent,
        binary,
        try_load_manifest,
        || launchd::bootout_launch_agent(sandboxed),
        request_shutdown_if_running,
        wait_for_daemon_shutdown,
        || launchd::restart_launch_agent(sandboxed),
        |binary| {
            let mut child = spawn_daemon(sandboxed, binary)?;
            let _ = wait_for_healthy_daemon(Some(&mut child))?;
            Ok(())
        },
        || {
            let _ = wait_for_healthy_daemon(None)?;
            Ok(())
        },
    )
}

#[expect(
    clippy::too_many_arguments,
    reason = "dependency-injected test seams require one parameter per collaborator"
)]
fn restart_daemon_with<
    LoadManifest,
    Bootout,
    RequestShutdown,
    WaitShutdown,
    RestartLaunchAgent,
    StartManualDaemon,
    WaitForLaunchdHealth,
>(
    launchd_enabled: bool,
    launch_agent: &launchd::LaunchAgentStatus,
    binary: &Path,
    mut load_manifest: LoadManifest,
    mut bootout: Bootout,
    mut request_shutdown: RequestShutdown,
    mut wait_for_shutdown: WaitShutdown,
    mut restart_launch_agent: RestartLaunchAgent,
    mut start_manual_daemon: StartManualDaemon,
    mut wait_for_launchd_health: WaitForLaunchdHealth,
) -> Result<DaemonControlResponse, CliError>
where
    LoadManifest: FnMut() -> Result<Option<super::state::DaemonManifest>, CliError>,
    Bootout: FnMut() -> Result<bool, CliError>,
    RequestShutdown: FnMut() -> Result<bool, CliError>,
    WaitShutdown: FnMut(&str) -> Result<(), CliError>,
    RestartLaunchAgent: FnMut() -> Result<(), CliError>,
    StartManualDaemon: FnMut(&Path) -> Result<(), CliError>,
    WaitForLaunchdHealth: FnMut() -> Result<(), CliError>,
{
    if launchd_enabled && launch_agent.loaded {
        let manifest = load_manifest()?;
        let booted_out = bootout()?;
        if booted_out && let Some(manifest) = manifest.as_ref() {
            wait_for_shutdown(&manifest.endpoint)?;
        }
    }

    let _ = request_shutdown()?;

    if launchd_enabled && launch_agent.installed {
        restart_launch_agent()?;
        wait_for_launchd_health()?;
    } else {
        start_manual_daemon(binary)?;
    }

    Ok(DaemonControlResponse {
        status: "restarted".into(),
    })
}

fn request_shutdown_if_running() -> Result<bool, CliError> {
    let Some(manifest) = try_load_manifest()? else {
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

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn wait_for_daemon_shutdown(endpoint: &str) -> Result<(), CliError> {
    tracing::info!(%endpoint, "waiting for daemon shutdown");
    wait_for_flag(&format!("wait for daemon shutdown at {endpoint}"), || {
        if state::daemon_lock_is_held() {
            return Ok(false);
        }
        if let Ok(Some(manifest)) = try_load_manifest()
            && manifest.endpoint == endpoint
        {
            let _ = state::clear_manifest_for_pid(manifest.pid);
        }
        tracing::info!("daemon shutdown confirmed (flock released)");
        Ok(true)
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn wait_for_healthy_daemon(mut child: Option<&mut Child>) -> Result<String, CliError> {
    tracing::info!("waiting for daemon health");
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

        let Some(manifest) = try_load_manifest()? else {
            return Ok(None);
        };
        if daemon_is_healthy(&manifest.endpoint) {
            tracing::info!(endpoint = %manifest.endpoint, "daemon healthy");
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

fn try_load_manifest() -> Result<Option<super::state::DaemonManifest>, CliError> {
    match super::state::load_manifest() {
        Ok(manifest) => Ok(manifest),
        Err(error) if error.code() == "KSRCLI014" => Ok(None),
        Err(error) => Err(error),
    }
}

fn daemon_url(endpoint: &str, path: &str) -> String {
    format!("{}{path}", endpoint.trim_end_matches('/'))
}

fn spawn_daemon(sandboxed: bool, binary: &Path) -> Result<Child, CliError> {
    if sandboxed {
        return Err(CliError::from(CliErrorKind::sandbox_feature_disabled(
            "daemon-spawn",
        )));
    }
    let log_path = state::daemon_root().join("daemon.stderr.log");
    let _ = fs::create_dir_all(state::daemon_root());
    let stderr_file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("open daemon log {}: {error}", log_path.display()))
        })?;

    Command::new(binary)
        .args(["daemon", "serve", "--host", "127.0.0.1", "--port", "0"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::from(stderr_file))
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::state;
    use clap::Parser;
    use std::cell::RefCell;
    use std::rc::Rc;

    #[derive(Debug, Parser)]
    struct DaemonServeArgsTestHarness {
        #[command(flatten)]
        args: DaemonServeArgs,
    }

    #[test]
    fn daemon_serve_args_default_is_unsandboxed() {
        let parsed = DaemonServeArgsTestHarness::try_parse_from(["test"]).unwrap();
        assert!(!parsed.args.sandboxed);
    }

    #[test]
    fn daemon_serve_args_accepts_sandboxed_flag() {
        let parsed = DaemonServeArgsTestHarness::try_parse_from(["test", "--sandboxed"]).unwrap();
        assert!(parsed.args.sandboxed);
    }

    #[test]
    fn daemon_serve_args_enables_sandbox_via_env() {
        temp_env::with_var("HARNESS_SANDBOXED", Some("1"), || {
            let parsed = DaemonServeArgsTestHarness::try_parse_from(["test"]).unwrap();
            let effective = parsed.args.sandboxed || service::sandboxed_from_env();
            assert!(effective);
        });
    }

    #[test]
    fn daemon_serve_args_ignores_env_when_unset() {
        temp_env::with_var("HARNESS_SANDBOXED", Option::<&str>::None, || {
            let parsed = DaemonServeArgsTestHarness::try_parse_from(["test"]).unwrap();
            let effective = parsed.args.sandboxed || service::sandboxed_from_env();
            assert!(!effective);
        });
    }

    fn sample_launch_agent_status(installed: bool, loaded: bool) -> launchd::LaunchAgentStatus {
        launchd::LaunchAgentStatus {
            installed,
            loaded,
            label: "io.harness.daemon".to_string(),
            path: "/tmp/io.harness.daemon.plist".to_string(),
            domain_target: "gui/501".to_string(),
            service_target: "gui/501/io.harness.daemon".to_string(),
            state: None,
            pid: None,
            last_exit_status: None,
            status_error: None,
        }
    }

    fn sample_manifest(endpoint: &str) -> state::DaemonManifest {
        state::DaemonManifest {
            version: "18.3.0".to_string(),
            pid: 42,
            endpoint: endpoint.to_string(),
            started_at: "2026-04-04T00:00:00Z".to_string(),
            token_path: "/tmp/auth-token".to_string(),
            sandboxed: false,
            codex_transport: "stdio".to_string(),
            codex_endpoint: None,
        }
    }

    #[test]
    fn stop_launchd_boots_out_then_reports_stopped() {
        let calls = Rc::new(RefCell::new(Vec::<String>::new()));
        let response = stop_daemon_with(
            true,
            &sample_launch_agent_status(true, true),
            {
                let calls = Rc::clone(&calls);
                move || {
                    calls.borrow_mut().push("load_manifest".to_string());
                    Ok(Some(sample_manifest("http://127.0.0.1:7000")))
                }
            },
            {
                let calls = Rc::clone(&calls);
                move || {
                    calls.borrow_mut().push("bootout".to_string());
                    Ok(true)
                }
            },
            {
                let calls = Rc::clone(&calls);
                move || {
                    calls.borrow_mut().push("request_shutdown".to_string());
                    Ok(false)
                }
            },
            {
                let calls = Rc::clone(&calls);
                move |endpoint| {
                    calls.borrow_mut().push(format!("wait_shutdown:{endpoint}"));
                    Ok(())
                }
            },
        )
        .expect("stop daemon");

        assert_eq!(response.status, "stopped");
        assert_eq!(
            calls.borrow().as_slice(),
            [
                "load_manifest",
                "bootout",
                "wait_shutdown:http://127.0.0.1:7000",
                "request_shutdown",
            ]
        );
    }

    #[test]
    fn stop_launchd_missing_runtime_is_still_success() {
        let calls = Rc::new(RefCell::new(Vec::<String>::new()));
        let response = stop_daemon_with(
            true,
            &sample_launch_agent_status(true, false),
            {
                let calls = Rc::clone(&calls);
                move || {
                    calls.borrow_mut().push("load_manifest".to_string());
                    Ok(Some(sample_manifest("http://127.0.0.1:7001")))
                }
            },
            {
                let calls = Rc::clone(&calls);
                move || {
                    calls.borrow_mut().push("bootout".to_string());
                    Ok(false)
                }
            },
            {
                let calls = Rc::clone(&calls);
                move || {
                    calls.borrow_mut().push("request_shutdown".to_string());
                    Ok(false)
                }
            },
            |_endpoint| panic!("shutdown wait should be skipped when bootout reports no runtime"),
        )
        .expect("stop daemon");

        assert_eq!(response.status, "stopped");
        assert_eq!(
            calls.borrow().as_slice(),
            ["load_manifest", "bootout", "request_shutdown"]
        );
    }

    #[test]
    fn stop_without_manifest_returns_success() {
        let calls = Rc::new(RefCell::new(Vec::<String>::new()));
        let response = stop_daemon_with(
            false,
            &sample_launch_agent_status(false, false),
            || panic!("manual stop should not read launchd manifest when launchd is disabled"),
            || panic!("manual stop should not call launchd bootout when launchd is disabled"),
            {
                let calls = Rc::clone(&calls);
                move || {
                    calls.borrow_mut().push("request_shutdown".to_string());
                    Ok(false)
                }
            },
            |_endpoint| panic!("no shutdown wait expected when nothing is running"),
        )
        .expect("stop daemon");

        assert_eq!(response.status, "stopped");
        assert_eq!(calls.borrow().as_slice(), ["request_shutdown"]);
    }

    #[test]
    fn restart_loaded_launch_agent_boots_out_then_uses_launchd_path() {
        let calls = Rc::new(RefCell::new(Vec::<String>::new()));
        let response = restart_daemon_with(
            true,
            &sample_launch_agent_status(true, true),
            Path::new("/tmp/harness"),
            {
                let calls = Rc::clone(&calls);
                move || {
                    calls.borrow_mut().push("load_manifest".to_string());
                    Ok(Some(sample_manifest("http://127.0.0.1:7002")))
                }
            },
            {
                let calls = Rc::clone(&calls);
                move || {
                    calls.borrow_mut().push("bootout".to_string());
                    Ok(true)
                }
            },
            {
                let calls = Rc::clone(&calls);
                move || {
                    calls.borrow_mut().push("request_shutdown".to_string());
                    Ok(false)
                }
            },
            {
                let calls = Rc::clone(&calls);
                move |endpoint| {
                    calls.borrow_mut().push(format!("wait_shutdown:{endpoint}"));
                    Ok(())
                }
            },
            {
                let calls = Rc::clone(&calls);
                move || {
                    calls.borrow_mut().push("restart_launch_agent".to_string());
                    Ok(())
                }
            },
            |_binary| panic!("manual daemon path should not run when a launch agent is installed"),
            {
                let calls = Rc::clone(&calls);
                move || {
                    calls.borrow_mut().push("wait_launchd_health".to_string());
                    Ok(())
                }
            },
        )
        .expect("restart daemon");

        assert_eq!(response.status, "restarted");
        assert_eq!(
            calls.borrow().as_slice(),
            [
                "load_manifest",
                "bootout",
                "wait_shutdown:http://127.0.0.1:7002",
                "request_shutdown",
                "restart_launch_agent",
                "wait_launchd_health",
            ]
        );
    }

    #[test]
    fn restart_installed_but_offline_launch_agent_skips_manual_spawn() {
        let calls = Rc::new(RefCell::new(Vec::<String>::new()));
        let response = restart_daemon_with(
            true,
            &sample_launch_agent_status(true, false),
            Path::new("/tmp/harness"),
            || panic!("offline launch agent restart should not read the manifest"),
            || panic!("offline launch agent restart should not boot out a missing runtime"),
            {
                let calls = Rc::clone(&calls);
                move || {
                    calls.borrow_mut().push("request_shutdown".to_string());
                    Ok(false)
                }
            },
            |_endpoint| panic!("offline launch agent restart should not wait for shutdown"),
            {
                let calls = Rc::clone(&calls);
                move || {
                    calls.borrow_mut().push("restart_launch_agent".to_string());
                    Ok(())
                }
            },
            |_binary| panic!("manual daemon path should not run when a launch agent is installed"),
            {
                let calls = Rc::clone(&calls);
                move || {
                    calls.borrow_mut().push("wait_launchd_health".to_string());
                    Ok(())
                }
            },
        )
        .expect("restart daemon");

        assert_eq!(response.status, "restarted");
        assert_eq!(
            calls.borrow().as_slice(),
            [
                "request_shutdown",
                "restart_launch_agent",
                "wait_launchd_health"
            ]
        );
    }

    #[test]
    fn restart_manual_path_stops_then_spawns_replacement() {
        let calls = Rc::new(RefCell::new(Vec::<String>::new()));
        let response = restart_daemon_with(
            false,
            &sample_launch_agent_status(false, false),
            Path::new("/tmp/harness"),
            || panic!("manual restart should not read a launchd manifest"),
            || panic!("manual restart should not call launchd bootout"),
            {
                let calls = Rc::clone(&calls);
                move || {
                    calls.borrow_mut().push("request_shutdown".to_string());
                    Ok(true)
                }
            },
            |_endpoint| panic!("manual restart should not use launchd shutdown waiting"),
            || panic!("manual restart should not restart launchd"),
            {
                let calls = Rc::clone(&calls);
                move |binary| {
                    calls
                        .borrow_mut()
                        .push(format!("start_manual:{}", binary.display()));
                    Ok(())
                }
            },
            || panic!("manual restart should not wait on launchd health"),
        )
        .expect("restart daemon");

        assert_eq!(response.status, "restarted");
        assert_eq!(
            calls.borrow().as_slice(),
            ["request_shutdown", "start_manual:/tmp/harness"]
        );
    }

    #[test]
    fn spawn_daemon_refuses_in_sandbox_mode() {
        let error = spawn_daemon(true, Path::new("/nonexistent/harness"))
            .expect_err("sandbox mode must refuse spawn");
        assert_eq!(error.code(), "SANDBOX001");
        assert!(error.to_string().contains("daemon-spawn"));
    }
}
