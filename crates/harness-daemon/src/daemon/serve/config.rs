use std::time::Duration;

use crate::daemon::codex_transport::CodexTransportKind;
use crate::daemon::http::CompanionRouteConfig;
use crate::daemon::server_state::{DaemonHttpAuthMode, RemoteRequestLimitConfig};
use crate::daemon::{is_local_websocket_endpoint, is_loopback_host};
use harness_daemon_provider_credentials::ProviderCredentialStartupMode;
use harness_kernel::errors::{CliError, CliErrorKind};

#[derive(Debug, Clone)]
pub struct DaemonServeConfig {
    pub host: String,
    pub port: u16,
    pub auth_mode: DaemonHttpAuthMode,
    pub remote_domain: Option<String>,
    pub remote_request_limits: Option<RemoteRequestLimitConfig>,
    /// Companion service to forward a configured path subtree to. Remote serve
    /// only; a loopback daemon serves its own routes and nothing else.
    pub companion: Option<CompanionRouteConfig>,
    pub poll_interval: Duration,
    pub observe_interval: Duration,
    /// Whether the daemon is running inside the macOS App Sandbox.
    ///
    /// When true, subprocess-based platform integration (e.g. `launchctl`
    /// invocations, respawning the daemon binary directly) is disabled and
    /// surfaces a structured error instead of attempting the operation.
    pub sandboxed: bool,
    /// How the daemon should reach its Codex app-server. Sandboxed daemons
    /// default to WebSocket because they cannot spawn subprocesses; the
    /// unsandboxed default is stdio. See
    /// [`codex_transport::codex_transport_from_env`](crate::daemon::codex_transport::codex_transport_from_env).
    pub codex_transport: CodexTransportKind,
    /// Whether startup restores provider tokens itself or waits for a trusted
    /// client such as Harness Monitor to hand them off.
    pub provider_credential_startup: ProviderCredentialStartupMode,
}

impl Default for DaemonServeConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".into(),
            port: 0,
            auth_mode: DaemonHttpAuthMode::Local,
            remote_domain: None,
            remote_request_limits: None,
            companion: None,
            poll_interval: Duration::from_secs(2),
            observe_interval: Duration::from_secs(5),
            sandboxed: false,
            codex_transport: CodexTransportKind::Stdio,
            provider_credential_startup: ProviderCredentialStartupMode::Keychain,
        }
    }
}

/// Returns true when the current working directory is under
/// `Library/Group Containers/`, which is a strong signal that the process
/// launched inside the macOS App Sandbox.
#[must_use]
pub(crate) fn cwd_looks_sandboxed() -> bool {
    std::env::current_dir()
        .ok()
        .and_then(|path| path.into_os_string().into_string().ok())
        .is_some_and(|path| path.contains("Library/Group Containers/"))
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
pub(crate) fn log_sandbox_startup(sandboxed: bool) {
    tracing::info!(sandboxed, "daemon starting");
    if !sandboxed && cwd_looks_sandboxed() {
        tracing::warn!(
            "daemon cwd is under Library/Group Containers/ but HARNESS_SANDBOXED is unset; \
             subprocess features may fail under the macOS App Sandbox"
        );
    }
}

pub(crate) const fn http_auth_mode(config: &DaemonServeConfig) -> DaemonHttpAuthMode {
    config.auth_mode
}

pub(crate) fn validate_serve_config(config: &DaemonServeConfig) -> Result<(), CliError> {
    if !is_loopback_host(&config.host) {
        return Err(CliErrorKind::workflow_parse(format!(
            "daemon host must be loopback-only: {}",
            config.host
        ))
        .into());
    }
    if let CodexTransportKind::WebSocket { endpoint } = &config.codex_transport
        && config.sandboxed
        && !is_local_websocket_endpoint(endpoint)
    {
        return Err(CliErrorKind::workflow_parse(format!(
            "sandboxed Codex websocket endpoint must be loopback-only: {endpoint}"
        ))
        .into());
    }
    Ok(())
}
