use crate::daemon::http::DaemonHttpAuthMode;
use crate::daemon::service::{
    CodexTransportKind, DaemonServeConfig, is_local_websocket_endpoint, is_loopback_host,
};
use crate::errors::{CliError, CliErrorKind};

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
