use std::env::current_exe;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::LazyLock;
use std::thread;
use std::time::{Duration, Instant};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::exec::RUNTIME;

use super::super::discovery::{self, AdoptionOutcome};
use super::super::launchd;
use super::super::protocol::DaemonControlResponse;
use super::super::service;
use super::super::state;

const DAEMON_CONTROL_TIMEOUT: Duration = Duration::from_secs(15);
const DAEMON_CONTROL_POLL_INTERVAL: Duration = Duration::from_millis(50);
const DAEMON_HTTP_TIMEOUT: Duration = Duration::from_secs(2);

static DAEMON_HTTP_CLIENT: LazyLock<reqwest::Client> = LazyLock::new(reqwest::Client::new);

#[expect(
    clippy::cognitive_complexity,
    reason = "explicit outcome-specific logging keeps daemon root adoption auditable"
)]
pub(super) fn adopt_daemon_root_for_transport_command(command: &'static str) {
    match discovery::adopt_running_daemon_root() {
        AdoptionOutcome::AlreadyCoherent { root } => {
            tracing::debug!(
                command,
                root = %root.display(),
                "daemon: root already coherent"
            );
        }
        AdoptionOutcome::Adopted { from, to } => {
            tracing::info!(
                command,
                from = %from.display(),
                to = %to.display(),
                "daemon: adopted running daemon root"
            );
        }
        AdoptionOutcome::NoRunningDaemon { default_root } => {
            tracing::debug!(
                command,
                default_root = %default_root.display(),
                "daemon: no running daemon found during root adoption"
            );
        }
    }
}

pub(super) fn resolve_current_exe_for(context: &'static str) -> Result<PathBuf, CliError> {
    current_exe().map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "resolve current harness binary for {context}: {error}"
        )))
    })
}

pub(super) fn exit_code_from_status(status: ExitStatus) -> i32 {
    if let Some(code) = status.code() {
        return code;
    }
    signal_exit_code(status).unwrap_or(1)
}

#[cfg(unix)]
fn signal_exit_code(status: ExitStatus) -> Option<i32> {
    use std::os::unix::process::ExitStatusExt;
    status.signal().map(|signal| 128 + signal)
}

#[cfg(not(unix))]
fn signal_exit_code(_status: ExitStatus) -> Option<i32> {
    None
}

pub(super) fn stop_daemon() -> Result<DaemonControlResponse, CliError> {
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

pub(super) fn stop_daemon_with<LoadManifest, Bootout, RequestShutdown, WaitShutdown>(
    launchd_enabled: bool,
    launch_agent: &launchd::LaunchAgentStatus,
    mut load_manifest: LoadManifest,
    mut bootout: Bootout,
    mut request_shutdown: RequestShutdown,
    mut wait_for_shutdown: WaitShutdown,
) -> Result<DaemonControlResponse, CliError>
where
    LoadManifest: FnMut() -> Result<Option<state::DaemonManifest>, CliError>,
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

pub(super) fn restart_daemon(binary: &Path) -> Result<DaemonControlResponse, CliError> {
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
pub(super) fn restart_daemon_with<
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
    LoadManifest: FnMut() -> Result<Option<state::DaemonManifest>, CliError>,
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
    let token = load_daemon_token(&manifest.token_path)?;
    if !daemon_is_healthy(&manifest.endpoint, &token) {
        return Ok(false);
    }

    match post_stop_request(&manifest.endpoint, &token) {
        Ok(()) => {
            wait_for_daemon_shutdown(&manifest.endpoint)?;
            Ok(true)
        }
        Err(_error) if !daemon_is_healthy(&manifest.endpoint, &token) => {
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
        let token = load_daemon_token(&manifest.token_path)?;
        if daemon_is_healthy(&manifest.endpoint, &token) {
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

fn daemon_is_healthy(endpoint: &str, token: &str) -> bool {
    let url = daemon_url(endpoint, "/v1/health");
    RUNTIME.block_on(async {
        DAEMON_HTTP_CLIENT
            .get(&url)
            .bearer_auth(token)
            .timeout(DAEMON_HTTP_TIMEOUT)
            .send()
            .await
            .is_ok_and(|response| response.status().is_success())
    })
}

fn load_daemon_token(token_path: &str) -> Result<String, CliError> {
    let token = fs::read_to_string(token_path).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "read daemon token {token_path}: {error}"
        )))
    })?;
    let token = token.trim().to_string();
    if token.is_empty() {
        return Err(CliError::from(CliErrorKind::workflow_io(format!(
            "daemon token {token_path} is empty"
        ))));
    }
    Ok(token)
}

fn try_load_manifest() -> Result<Option<state::DaemonManifest>, CliError> {
    match state::load_manifest() {
        Ok(manifest) => Ok(manifest),
        Err(error) if error.code() == "KSRCLI014" => Ok(None),
        Err(error) => Err(error),
    }
}

fn daemon_url(endpoint: &str, path: &str) -> String {
    format!("{}{path}", endpoint.trim_end_matches('/'))
}

pub(super) fn spawn_daemon(sandboxed: bool, binary: &Path) -> Result<Child, CliError> {
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

pub(super) fn print_daemon_control_response(
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

pub(super) fn print_json<T: serde::Serialize>(value: &T) -> Result<(), CliError> {
    let json = serde_json::to_string_pretty(value)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    println!("{json}");
    Ok(())
}
