use super::*;

pub(super) fn start_detached(config: &ResolvedBridgeConfig) -> Result<i32, CliError> {
    let harness = current_exe().map_err(|error| {
        CliErrorKind::workflow_io(format!("resolve current harness binary: {error}"))
    })?;
    state::ensure_daemon_dirs()?;
    let stdout_path = state::daemon_root().join("bridge.stdout.log");
    let stderr_path = state::daemon_root().join("bridge.stderr.log");
    let stdout = File::create(&stdout_path).map_err(|error| {
        CliErrorKind::workflow_io(format!("create {}: {error}", stdout_path.display()))
    })?;
    let stderr = File::create(&stderr_path).map_err(|error| {
        CliErrorKind::workflow_io(format!("create {}: {error}", stderr_path.display()))
    })?;
    let mut command = Command::new(&harness);
    write_bridge_config(&config.persisted)?;
    command.arg("bridge").arg("start");
    let mut child = command
        .stdin(Stdio::null())
        .stdout(stdout)
        .stderr(stderr)
        .spawn()
        .map_err(|error| CliErrorKind::workflow_io(format!("spawn bridge: {error}")))?;
    wait_for_detached_bridge_start(&mut child, config, &stdout_path, &stderr_path)?;
    println!("bridge started in background (pid {})", child.id());
    Ok(0)
}

fn wait_for_detached_bridge_start(
    child: &mut Child,
    config: &ResolvedBridgeConfig,
    stdout_path: &Path,
    stderr_path: &Path,
) -> Result<(), CliError> {
    let deadline = Instant::now() + DETACHED_START_TIMEOUT;
    let expected_socket = config.socket_path.display().to_string();
    loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|error| CliErrorKind::workflow_io(format!("poll bridge start: {error}")))?
        {
            return Err(detached_start_failure(status, stdout_path, stderr_path));
        }

        if let Some(running) = resolve_running_bridge(LivenessMode::HostAuthoritative)?
            && running.state.pid == child.id()
            && running.report.running
            && running.report.socket_path.as_deref() == Some(expected_socket.as_str())
        {
            return Ok(());
        }

        if Instant::now() >= deadline {
            let stdout_hint = log_excerpt(stdout_path);
            let stderr_hint = log_excerpt(stderr_path);
            return Err(CliErrorKind::workflow_io(format!(
                "bridge start timed out before publishing live state for {} (stdout log: {}; stderr log: {}; stdout tail: {}; stderr tail: {})",
                expected_socket,
                stdout_path.display(),
                stderr_path.display(),
                stdout_hint,
                stderr_hint
            ))
            .into());
        }

        thread::sleep(DETACHED_START_POLL_INTERVAL);
    }
}

fn detached_start_failure(status: ExitStatus, stdout_path: &Path, stderr_path: &Path) -> CliError {
    CliErrorKind::workflow_io(format!(
        "bridge background child exited early with status {status} (stdout log: {}; stderr log: {}; stdout tail: {}; stderr tail: {})",
        stdout_path.display(),
        stderr_path.display(),
        log_excerpt(stdout_path),
        log_excerpt(stderr_path)
    ))
    .into()
}

fn log_excerpt(path: &Path) -> String {
    let Ok(contents) = fs::read_to_string(path) else {
        return "unavailable".to_string();
    };
    let trimmed = contents.trim();
    if trimmed.is_empty() {
        return "empty".to_string();
    }
    let lines: Vec<&str> = trimmed.lines().collect();
    let start = lines.len().saturating_sub(4);
    lines[start..].join(" | ")
}

fn wait_until_dead(pid: u32, grace: Duration) -> Result<(), CliError> {
    if wait_until_pid_dead(pid, grace) {
        return Ok(());
    }
    send_sigterm(pid)?;
    if wait_until_pid_dead(pid, grace) {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!(
        "bridge stop: pid {pid} still alive after {}s",
        grace.as_secs()
    ))
    .into())
}

fn wait_until<F>(grace: Duration, mut predicate: F) -> bool
where
    F: FnMut() -> bool,
{
    let start = Instant::now();
    while start.elapsed() < grace {
        if predicate() {
            return true;
        }
        thread::sleep(STOP_POLL_INTERVAL);
    }
    false
}

fn wait_until_bridge_lock_released(grace: Duration) -> bool {
    wait_until(grace, || !bridge_lock_is_held())
}

fn wait_until_bridge_rpc_unavailable(client: &BridgeClient, grace: Duration) -> bool {
    wait_until(grace, || client.status().is_err())
}

fn force_stop_via_signal_if_possible(
    running: &ResolvedRunningBridge,
    grace: Duration,
    wait_for_stop: impl Fn() -> bool,
) -> Result<bool, CliError> {
    if super::service::sandboxed_from_env() || !pid_alive(running.state.pid) {
        return Ok(false);
    }
    send_sigterm(running.state.pid)?;
    Ok(wait_for_stop() || wait_until_pid_dead(running.state.pid, grace))
}

pub(super) fn wait_until_bridge_dead(
    running: &ResolvedRunningBridge,
    grace: Duration,
) -> Result<(), CliError> {
    match running.proof {
        BridgeProof::Lock => {
            if wait_until_bridge_lock_released(grace) {
                return Ok(());
            }
            if force_stop_via_signal_if_possible(running, grace, || {
                wait_until_bridge_lock_released(grace)
            })? {
                return Ok(());
            }
            Err(CliErrorKind::workflow_io(format!(
                "bridge stop: bridge.lock still held after {}s",
                grace.as_secs()
            ))
            .into())
        }
        BridgeProof::Rpc => {
            let Some(client) = running.client.as_ref() else {
                return Err(CliErrorKind::workflow_io(
                    "bridge stop: live RPC proof missing client",
                )
                .into());
            };
            if wait_until_bridge_rpc_unavailable(client, grace) {
                return Ok(());
            }
            if force_stop_via_signal_if_possible(running, grace, || {
                wait_until_bridge_rpc_unavailable(client, grace)
            })? {
                return Ok(());
            }
            Err(CliErrorKind::workflow_io(format!(
                "bridge stop: bridge RPC still responding after {}s",
                grace.as_secs()
            ))
            .into())
        }
        BridgeProof::Pid => wait_until_dead(running.state.pid, grace),
    }
}

fn wait_until_pid_dead(pid: u32, grace: Duration) -> bool {
    let start = Instant::now();
    while start.elapsed() < grace {
        if !pid_alive(pid) {
            return true;
        }
        thread::sleep(STOP_POLL_INTERVAL);
    }
    false
}

fn send_sigterm(pid: u32) -> Result<(), CliError> {
    let status = Command::new("/bin/kill")
        .args(["-TERM", &pid.to_string()])
        .status()
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("run /bin/kill -TERM {pid}: {error}"))
        })?;
    if status.success() || !pid_alive(pid) {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!("/bin/kill -TERM {pid} exited with {status}")).into())
}

pub(super) fn bridge_response_error(response: BridgeResponse) -> CliError {
    let code = response.code.unwrap_or_else(|| "UNKNOWN".to_string());
    let message = response
        .message
        .unwrap_or_else(|| "unknown bridge error".to_string());
    let detail = bridge_response_detail(&message);
    let error = match code.as_str() {
        "SANDBOX001" => CliError::from(CliErrorKind::sandbox_feature_disabled(detail)),
        "CODEX001" => CliError::from(CliErrorKind::codex_server_unavailable(detail)),
        "WORKFLOW_PARSE" => CliError::from(CliErrorKind::workflow_parse(message)),
        "WORKFLOW_SERIALIZE" => CliError::from(CliErrorKind::workflow_serialize(detail)),
        "WORKFLOW_VERSION" => CliError::from(CliErrorKind::workflow_version(detail)),
        "WORKFLOW_CONCURRENT" => CliError::from(CliErrorKind::concurrent_modification(detail)),
        "KSRCLI090" => CliError::from(CliErrorKind::session_not_active(detail)),
        "KSRCLI091" => CliError::from(CliErrorKind::session_permission_denied(detail)),
        "KSRCLI092" => CliError::from(CliErrorKind::session_agent_conflict(detail)),
        "WORKFLOW_IO" => CliError::from(CliErrorKind::workflow_io(message)),
        _ => CliError::from(CliErrorKind::workflow_io(format!(
            "bridge error {code}: {message}"
        ))),
    };
    if let Some(details) = response.details {
        error.with_details(details)
    } else {
        error
    }
}

fn bridge_response_detail(message: &str) -> String {
    message.split_once(": ").map_or_else(
        || message.trim().to_string(),
        |(_, detail)| detail.trim().to_string(),
    )
}
