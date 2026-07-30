use std::env;

pub use harness_daemon_codex::{
    CodexTransport, CodexTransportKind, DEFAULT_CODEX_WS_ENDPOINT, StdioCodexTransport,
    WebSocketCodexTransport,
};

use super::bridge;

#[cfg(test)]
mod tests;

/// Resolve the transport kind for a given daemon sandbox mode, consulting
/// (in order) an explicit `HARNESS_CODEX_WS_URL`, the unified host bridge
/// state file, and finally the sandbox default.
///
/// Sandboxed daemons always use WebSocket because they cannot spawn child
/// processes. Unsandboxed daemons default to stdio unless the operator or a
/// running bridge selects WebSocket.
#[must_use]
pub fn codex_transport_from_env(sandboxed: bool) -> CodexTransportKind {
    let override_url = env::var("HARNESS_CODEX_WS_URL")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());

    if let Some(endpoint) =
        override_url.and_then(|endpoint| sandboxed_websocket_endpoint(sandboxed, endpoint, "env"))
    {
        return CodexTransportKind::WebSocket { endpoint };
    }

    if let Some(endpoint) = bridge_endpoint_from_state_file()
        .and_then(|endpoint| sandboxed_websocket_endpoint(sandboxed, endpoint, "bridge"))
    {
        return CodexTransportKind::WebSocket { endpoint };
    }

    if sandboxed {
        return CodexTransportKind::WebSocket {
            endpoint: DEFAULT_CODEX_WS_ENDPOINT.to_string(),
        };
    }

    CodexTransportKind::Stdio
}

fn sandboxed_websocket_endpoint(
    sandboxed: bool,
    endpoint: String,
    source: &'static str,
) -> Option<String> {
    if !sandboxed || super::is_local_websocket_endpoint(&endpoint) {
        return Some(endpoint);
    }
    log_rejected_sandboxed_endpoint(source, &endpoint);
    None
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_rejected_sandboxed_endpoint(source: &'static str, endpoint: &str) {
    tracing::warn!(
        source,
        endpoint,
        "ignoring non-loopback Codex websocket endpoint for sandboxed daemon"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn bridge_endpoint_from_state_file() -> Option<String> {
    match bridge::codex_websocket_endpoint() {
        Ok(endpoint) => endpoint,
        Err(error) => {
            tracing::warn!(%error, "failed to read bridge state file; falling back to defaults");
            None
        }
    }
}
