use super::*;

pub(super) fn matches_running_config(config: &ResolvedBridgeConfig) -> Result<bool, CliError> {
    let Some(running) = resolve_running_bridge(LivenessMode::HostAuthoritative)? else {
        return Ok(false);
    };
    if running.report.socket_path.as_deref() != Some(config.socket_path.to_string_lossy().as_ref())
    {
        return Ok(false);
    }
    let running_capabilities: BTreeSet<&str> = running
        .report
        .capabilities
        .keys()
        .map(String::as_str)
        .collect();
    let requested_capabilities: BTreeSet<&str> = config
        .capabilities
        .iter()
        .map(|capability| capability.name())
        .collect();
    if running_capabilities != requested_capabilities {
        return Ok(false);
    }
    if let Some(codex_binary) = config.codex_binary.as_ref()
        && let Some(codex) = running.report.capabilities.get(BRIDGE_CAPABILITY_CODEX)
    {
        let port_matches = codex
            .metadata
            .get("port")
            .and_then(|value| value.parse::<u16>().ok())
            == Some(config.codex_port);
        let binary_matches =
            codex.metadata.get("binary_path") == Some(&codex_binary.display().to_string());
        return Ok(port_matches && binary_matches);
    }
    Ok(true)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "each branch handles a distinct server-lifecycle step; splitting further would obscure the flow"
)]
pub(super) fn run_bridge_server(config: &ResolvedBridgeConfig) -> Result<i32, CliError> {
    state::ensure_daemon_dirs()?;
    // Acquire the bridge lock BEFORE unlinking the socket so a racing second
    // `harness bridge start` cannot unlink the live socket of the first
    // instance before failing its own lock acquisition.
    let _bridge_lock = acquire_bridge_lock_exclusive()?;
    tracing::info!(path = %bridge_lock_path().display(), "bridge lock acquired");
    remove_if_exists(&config.socket_path)?;
    let listener = UnixListener::bind(&config.socket_path).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "bind bridge socket {}: {error}",
            config.socket_path.display()
        ))
    })?;
    // Arm a socket guard immediately after bind so that any subsequent error
    // return, panic, or unexpected accept failure still unlinks the socket.
    // The happy-path cleanup is handled by `clear_bridge_state()` below and
    // disarms the guard so it does not double-unlink.
    let mut socket_guard = BridgeSocketGuard::new(config.socket_path.clone());
    let mut state_guard = BridgeStateGuard::new();
    fs::set_permissions(&config.socket_path, Permissions::from_mode(0o600)).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "set bridge socket permissions {}: {error}",
            config.socket_path.display()
        ))
    })?;

    let token = state::ensure_auth_token()?;
    let capabilities = initial_capabilities(config);
    let server = Arc::new(BridgeServer::new(
        token,
        config.socket_path.clone(),
        config.persisted.clone(),
        capabilities,
    ));
    write_bridge_config(&config.persisted)?;
    if config.capabilities.contains(&BridgeCapability::Codex) {
        server.enable_codex(config)?;
    }
    server.persist_state()?;

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => handle_stream(&server, stream)?,
            Err(error) => {
                return Err(CliErrorKind::workflow_io(format!(
                    "accept bridge connection: {error}"
                ))
                .into());
            }
        }
        if server.shutdown_requested() {
            break;
        }
    }
    server.cleanup();
    clear_bridge_state()?;
    socket_guard.disarm();
    state_guard.disarm();
    Ok(0)
}

/// RAII guard that unlinks the bridge unix socket file on drop, unless
/// `disarm()` is called. Installed by `run_bridge_server` right after
/// `bind()` so any error return, panic, or unexpected exit still cleans
/// up the socket file (signal-delivered `SIGKILL` remains a leak vector
/// and is handled by `mise run clean:stale`).
pub(super) struct BridgeSocketGuard {
    path: PathBuf,
    armed: bool,
}

impl BridgeSocketGuard {
    pub(super) fn new(path: PathBuf) -> Self {
        Self { path, armed: true }
    }

    pub(super) fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for BridgeSocketGuard {
    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score past the default threshold"
    )]
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        if let Err(error) = fs::remove_file(&self.path)
            && error.kind() != ErrorKind::NotFound
        {
            tracing::warn!(
                path = %self.path.display(),
                %error,
                "failed to unlink bridge socket on drop"
            );
        }
    }
}

/// RAII guard that removes persisted bridge state on drop unless `disarm()`
/// is called. Installed by `run_bridge_server` so startup failures do not
/// leave stale bridge state behind.
struct BridgeStateGuard {
    armed: bool,
}

impl BridgeStateGuard {
    fn new() -> Self {
        Self { armed: true }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for BridgeStateGuard {
    #[expect(
        clippy::cognitive_complexity,
        reason = "drop path is tiny; tracing macro expansion trips the lint"
    )]
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        if let Err(error) = clear_bridge_state() {
            tracing::warn!(%error, "failed to clear bridge state on drop");
        }
    }
}

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

fn kill_codex_process(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

fn ensure_codex_port_available(port: u16) -> Result<(), String> {
    TcpListener::bind(("127.0.0.1", port))
        .map(drop)
        .map_err(|error| format!("127.0.0.1:{port} is unavailable: {error}"))
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
            kill_codex_process(&mut process.child);
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
    if let Err(error) = ensure_codex_port_available(port) {
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
        .spawn()
        .map_err(|error| CliErrorKind::workflow_io(format!("spawn codex app-server: {error}")))?;
    let version = detect_codex_version(binary);
    let pid = child.id();
    tracing::info!(
        binary_path = %binary.display(),
        endpoint = %listen_address,
        port,
        pid,
        "spawned codex app-server"
    );
    state::append_event_best_effort(
        "info",
        &format!("starting codex host bridge on {listen_address} (pid {pid})"),
    );
    let mut process = BridgeCodexProcess {
        child,
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

pub(super) fn initial_capabilities(
    config: &ResolvedBridgeConfig,
) -> BTreeMap<String, HostBridgeCapabilityManifest> {
    let mut capabilities = BTreeMap::new();
    if config.capabilities.contains(&BridgeCapability::AgentTui) {
        capabilities.insert(
            BRIDGE_CAPABILITY_AGENT_TUI.to_string(),
            HostBridgeCapabilityManifest {
                enabled: true,
                healthy: true,
                transport: "unix".to_string(),
                endpoint: Some(config.socket_path.display().to_string()),
                metadata: stringify_metadata_map(&BridgeAgentTuiMetadata { active_sessions: 0 }),
            },
        );
    }
    capabilities
}

fn handle_stream(server: &Arc<BridgeServer>, stream: UnixStream) -> Result<(), CliError> {
    let mut line = String::new();
    BufReader::new(
        stream
            .try_clone()
            .map_err(|error| CliErrorKind::workflow_io(format!("clone bridge stream: {error}")))?,
    )
    .read_line(&mut line)
    .map_err(|error| CliErrorKind::workflow_io(format!("read bridge request: {error}")))?;
    let response = match serde_json::from_str::<BridgeEnvelope>(&line) {
        Ok(envelope) => server.handle(envelope),
        Err(error) => {
            let error = CliError::from(CliErrorKind::workflow_parse(format!(
                "parse bridge request: {error}"
            )));
            BridgeResponse::error(&error)
        }
    };
    let payload = serde_json::to_string(&response)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    let mut writer = stream;
    writer
        .write_all(payload.as_bytes())
        .and_then(|()| writer.write_all(b"\n"))
        .and_then(|()| writer.flush())
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("write bridge response: {error}")).into()
        })
}
