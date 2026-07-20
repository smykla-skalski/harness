//! Codex app-server process lifecycle: spawn, readiness probing, and monitoring.

use std::io::{BufRead, BufReader, Write as _};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::os::unix::process::CommandExt as _;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use crate::agents::acp::supervision::kill_process_group;
use crate::daemon::state;
use crate::errors::{CliError, CliErrorKind};

use super::core::{BridgeCodexMetadata, BridgeCodexProcess, CodexEndpointScheme};
use super::helpers::detect_codex_version;
use super::server::BridgeServer;
use super::types::{
    CODEX_READY_POLL_INTERVAL, CODEX_READY_PROBE_TIMEOUT, CODEX_READY_TIMEOUT,
    CODEX_READY_WARN_AFTER,
};

fn codex_endpoint_address(endpoint: &str) -> Result<(CodexEndpointScheme, String), String> {
    let Some((scheme, address)) = CodexEndpointScheme::parse(endpoint) else {
        return Err(format!("unsupported codex endpoint '{endpoint}'"));
    };
    let address = address
        .split('/')
        .next()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("missing socket address in codex endpoint '{endpoint}'"))?;
    Ok((scheme, address.to_string()))
}

fn codex_endpoint_socket_addr(endpoint: &str) -> Result<SocketAddr, String> {
    let (_, address) = codex_endpoint_address(endpoint)?;
    address
        .to_socket_addrs()
        .map_err(|error| format!("resolve {address}: {error}"))?
        .next()
        .ok_or_else(|| format!("resolve {address}: no socket addresses returned"))
}

pub(crate) fn probe_codex_readiness(endpoint: &str, timeout: Duration) -> Result<(), String> {
    let (scheme, address) = codex_endpoint_address(endpoint)?;
    let socket_addr = codex_endpoint_socket_addr(endpoint)?;
    let mut stream = TcpStream::connect_timeout(&socket_addr, timeout)
        .map_err(|error| format!("connect {address}: {error}"))?;
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));

    if scheme == CodexEndpointScheme::SecureWebSocket {
        return Ok(());
    }

    let readyz_url = format!("http://{address}/readyz");
    let request = format!("GET /readyz HTTP/1.1\r\nHost: {address}\r\nConnection: close\r\n\r\n");
    stream
        .write_all(request.as_bytes())
        .map_err(|error| format!("write {readyz_url}: {error}"))?;

    let mut status_line = String::new();
    BufReader::new(stream)
        .read_line(&mut status_line)
        .map_err(|error| format!("read {readyz_url}: {error}"))?;
    let status_line = status_line.trim();
    if status_line.starts_with("HTTP/1.1 200") || status_line.starts_with("HTTP/1.0 200") {
        return Ok(());
    }
    Err(format!(
        "unexpected {readyz_url} response '{}'",
        if status_line.is_empty() {
            "<empty>"
        } else {
            status_line
        }
    ))
}

pub(super) fn kill_codex_process_group(process: &mut BridgeCodexProcess) {
    kill_process_group(process.pgid, &mut process.child);
}

#[expect(
    clippy::cognitive_complexity,
    reason = "startup/readiness loop is intentionally linear and log-heavy"
)]
fn wait_for_codex_process_ready(process: &mut BridgeCodexProcess) -> Result<(), CliError> {
    let endpoint = process.endpoint.clone();
    let port = process.metadata.port;
    let pid = process.child.id();
    let readyz_url = codex_endpoint_address(&endpoint).map_or_else(
        |_| endpoint.clone(),
        |(_, address)| format!("http://{address}/readyz"),
    );
    let started_at = Instant::now();
    let mut warned = false;

    loop {
        let probe_error = match probe_codex_readiness(&endpoint, CODEX_READY_PROBE_TIMEOUT) {
            Ok(()) => {
                tracing::info!(%endpoint, %readyz_url, port, pid, "codex app-server ready");
                return Ok(());
            }
            Err(error) => error,
        };

        if let Some(exit_status) = process
            .child
            .try_wait()
            .map_err(|error| CliErrorKind::workflow_io(format!("poll codex app-server: {error}")))?
        {
            let exit_status = exit_status.to_string();
            tracing::error!(
                %endpoint,
                %readyz_url,
                port,
                pid,
                exit_status = %exit_status,
                "codex app-server exited before readiness"
            );
            state::append_event_best_effort(
                "error",
                &format!("codex host bridge failed before readiness on {endpoint}: {exit_status}"),
            );
            return Err(CliErrorKind::workflow_io(format!(
                "codex app-server exited before readiness on {endpoint}: {exit_status}"
            ))
            .into());
        }

        if !warned && started_at.elapsed() >= CODEX_READY_WARN_AFTER {
            tracing::warn!(
                %endpoint,
                %readyz_url,
                port,
                pid,
                probe_error = %probe_error,
                "codex app-server readiness still pending"
            );
            state::append_event_best_effort(
                "warn",
                &format!("codex host bridge readiness still pending on {endpoint}: {probe_error}"),
            );
            warned = true;
        }

        if started_at.elapsed() >= CODEX_READY_TIMEOUT {
            tracing::error!(
                %endpoint,
                %readyz_url,
                port,
                pid,
                probe_error = %probe_error,
                timeout_ms = CODEX_READY_TIMEOUT.as_millis(),
                "codex app-server readiness timed out"
            );
            state::append_event_best_effort(
                "error",
                &format!("codex host bridge readiness timed out on {endpoint}: {probe_error}"),
            );
            kill_codex_process_group(process);
            return Err(CliErrorKind::workflow_io(format!(
                "codex app-server did not become ready on {endpoint}: {probe_error}"
            ))
            .into());
        }

        thread::sleep(CODEX_READY_POLL_INTERVAL);
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "spawn/setup path keeps process metadata, readiness, and audit together"
)]
pub(super) fn spawn_codex_process(
    binary: &Path,
    port: u16,
) -> Result<BridgeCodexProcess, CliError> {
    let listen_address = format!("ws://127.0.0.1:{port}");
    if let Err(error) = super::stale_codex::ensure_codex_port_available(port, binary) {
        tracing::error!(
            binary_path = %binary.display(),
            endpoint = %listen_address,
            port,
            %error,
            "codex app-server port unavailable before spawn"
        );
        state::append_event_best_effort(
            "error",
            &format!("codex host bridge failed before readiness on {listen_address}: {error}"),
        );
        return Err(CliErrorKind::workflow_io(format!(
            "codex app-server port check failed on {listen_address}: {error}"
        ))
        .into());
    }
    let child = Command::new(binary)
        .args(["app-server", "--listen", &listen_address])
        .stdin(Stdio::null())
        .process_group(0)
        .spawn()
        .map_err(|error| CliErrorKind::workflow_io(format!("spawn codex app-server: {error}")))?;
    let version = detect_codex_version(binary);
    let codex_pid = child.id();
    let group_leader = codex_pid.cast_signed();
    tracing::info!(
        binary_path = %binary.display(),
        endpoint = %listen_address,
        port,
        pid = codex_pid,
        pgid = group_leader,
        "spawned codex app-server"
    );
    state::append_event_best_effort(
        "info",
        &format!("starting codex host bridge on {listen_address} (pid {codex_pid})"),
    );
    let mut process = BridgeCodexProcess {
        child,
        pgid: group_leader,
        endpoint: listen_address,
        metadata: BridgeCodexMetadata {
            port,
            binary_path: binary.display().to_string(),
            version,
            last_exit_status: None,
        },
    };
    wait_for_codex_process_ready(&mut process)?;
    Ok(process)
}

pub(super) fn spawn_codex_monitor(server: Arc<BridgeServer>) {
    thread::spawn(move || {
        loop {
            if server.shutdown_requested() {
                return;
            }
            let result = {
                let Ok(mut codex) = server.codex.lock() else {
                    return;
                };
                let Some(process) = codex.as_mut() else {
                    return;
                };
                process
                    .child
                    .try_wait()
                    .ok()
                    .flatten()
                    .map(|status| status.to_string())
            };
            if let Some(status) = result {
                let _ = server.mark_codex_unhealthy(&status);
                return;
            }
            thread::sleep(Duration::from_millis(250));
        }
    });
}
