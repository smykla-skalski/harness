use super::{BridgeClient, Watcher, ResolvedRunningBridge, BridgeStatusReport, uptime_from_started_at, CliError, resolve_running_bridge, LivenessMode, clear_bridge_state, wait_until_bridge_dead, STOP_GRACE_PERIOD, BridgeReconfigureSpec, JoinHandle, PathBuf, RecommendedWatcher, mpsc, sleep, WATCH_DEBOUNCE, state, Path, host_bridge_manifest, RecursiveMode};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ShutdownRequestOutcome {
    Sent,
    MissingClient,
    SendFailed,
}

fn send_bridge_shutdown_request(client: Option<&BridgeClient>) -> ShutdownRequestOutcome {
    match client {
        Some(client) if client.shutdown().is_ok() => ShutdownRequestOutcome::Sent,
        Some(_) => ShutdownRequestOutcome::SendFailed,
        None => ShutdownRequestOutcome::MissingClient,
    }
}

fn bridge_shutdown_warning(outcome: ShutdownRequestOutcome) -> Option<&'static str> {
    match outcome {
        ShutdownRequestOutcome::Sent => None,
        ShutdownRequestOutcome::MissingClient => {
            Some("bridge stop: missing bridge client, skipping graceful shutdown request")
        }
        ShutdownRequestOutcome::SendFailed => Some("bridge stop: graceful shutdown request failed"),
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion in a leaf logging helper"
)]
fn log_bridge_shutdown_warning(message: &'static str) {
    tracing::warn!("{message}");
}

fn request_bridge_shutdown(running: &ResolvedRunningBridge) {
    if let Some(message) =
        bridge_shutdown_warning(send_bridge_shutdown_request(running.client.as_ref()))
    {
        log_bridge_shutdown_warning(message);
    }
}

#[must_use]
fn stopped_bridge_report(running: &ResolvedRunningBridge) -> BridgeStatusReport {
    BridgeStatusReport {
        running: false,
        socket_path: Some(running.state.socket_path.clone()),
        pid: Some(running.state.pid),
        started_at: Some(running.state.started_at.clone()),
        uptime_seconds: uptime_from_started_at(&running.state.started_at),
        capabilities: running.report.capabilities.clone(),
    }
}

/// Stop the running bridge and clean up its persisted state.
///
/// # Errors
/// Returns [`CliError`] when the bridge cannot be contacted or its state files
/// cannot be removed.
pub fn stop_bridge() -> Result<BridgeStatusReport, CliError> {
    let Some(running) = resolve_running_bridge(LivenessMode::HostAuthoritative)? else {
        clear_bridge_state()?;
        return Ok(BridgeStatusReport::not_running());
    };
    request_bridge_shutdown(&running);
    wait_until_bridge_dead(&running, STOP_GRACE_PERIOD)?;
    clear_bridge_state()?;
    Ok(stopped_bridge_report(&running))
}

/// Apply a capability reconfiguration to the running bridge.
///
/// # Errors
/// Returns [`CliError`] when the reconfiguration request is invalid, the
/// running bridge state cannot be loaded, or the bridge rejects the request.
pub fn reconfigure_bridge(
    enable: &[String],
    disable: &[String],
    force: bool,
) -> Result<BridgeStatusReport, CliError> {
    let request = BridgeReconfigureSpec::from_names(enable, disable, force)?;
    BridgeClient::from_state_file()?.reconfigure(&request)
}

/// Spawn the daemon manifest watcher that republishes bridge state changes.
#[must_use]
pub fn spawn_manifest_watcher() -> JoinHandle<()> {
    tokio::spawn(async move {
        run_manifest_watcher().await;
    })
}

async fn run_manifest_watcher() {
    let Some((_daemon_root, _watcher, mut event_rx)) = manifest_watcher_parts() else {
        return;
    };
    apply_bridge_state_to_manifest();
    drive_manifest_watcher(&mut event_rx).await;
}

enum ManifestWatcherSetupError {
    RootUnavailable,
    WatcherUnavailable,
}

#[expect(
    clippy::cognitive_complexity,
    reason = "warning dispatch branches are small and explicit here"
)]
fn manifest_watcher_parts() -> Option<(
    PathBuf,
    RecommendedWatcher,
    mpsc::Receiver<notify::Result<notify::Event>>,
)> {
    match setup_manifest_watcher() {
        Ok(parts) => Some(parts),
        Err(ManifestWatcherSetupError::RootUnavailable) => {
            tracing::warn!("bridge watcher: unable to ensure daemon root");
            None
        }
        Err(ManifestWatcherSetupError::WatcherUnavailable) => {
            tracing::warn!("bridge watcher: failed to build filesystem watcher");
            None
        }
    }
}

fn setup_manifest_watcher() -> Result<
    (
        PathBuf,
        RecommendedWatcher,
        mpsc::Receiver<notify::Result<notify::Event>>,
    ),
    ManifestWatcherSetupError,
> {
    let daemon_root = ensure_watcher_root().ok_or(ManifestWatcherSetupError::RootUnavailable)?;
    let (event_tx, event_rx) = mpsc::channel::<notify::Result<notify::Event>>(32);
    let watcher = build_manifest_watcher(&daemon_root, event_tx)
        .ok_or(ManifestWatcherSetupError::WatcherUnavailable)?;
    Ok((daemon_root, watcher, event_rx))
}

async fn drive_manifest_watcher(event_rx: &mut mpsc::Receiver<notify::Result<notify::Event>>) {
    while event_rx.recv().await.is_some() {
        sleep(WATCH_DEBOUNCE).await;
        while event_rx.try_recv().is_ok() {}
        apply_bridge_state_to_manifest();
    }
}

fn ensure_watcher_root() -> Option<PathBuf> {
    state::ensure_daemon_dirs().ok()?;
    Some(state::daemon_root())
}

fn build_manifest_watcher(
    daemon_root: &Path,
    event_tx: mpsc::Sender<notify::Result<notify::Event>>,
) -> Option<RecommendedWatcher> {
    create_manifest_watcher(event_tx).and_then(|watcher| watch_bridge_root(watcher, daemon_root))
}

/// Pure decision: given the current on-disk manifest return the manifest that
/// should be published, or `None` if the host-bridge state is unchanged.
///
/// Extracted as a pure function so the "did the watcher correctly decide to
/// publish an update?" branch can be unit-tested without standing up a real
/// daemon.
pub(crate) fn compute_bridge_manifest_update(
    current: &state::DaemonManifest,
) -> Option<state::DaemonManifest> {
    let host_bridge = host_bridge_manifest().ok()?;
    if current.host_bridge == host_bridge {
        return None;
    }
    Some(state::DaemonManifest {
        host_bridge,
        ..current.clone()
    })
}

fn apply_bridge_state_to_manifest() {
    let Some(current) = state::load_manifest().ok().flatten() else {
        return;
    };
    let Some(next) = compute_bridge_manifest_update(&current) else {
        return;
    };
    publish_bridge_manifest_update(&next);
}

fn write_bridge_manifest_update(manifest: &state::DaemonManifest) -> Result<(), CliError> {
    state::write_manifest(manifest).map(drop)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "single warning branch kept local to manifest publish failures"
)]
fn publish_bridge_manifest_update(manifest: &state::DaemonManifest) {
    if let Err(error) = write_bridge_manifest_update(manifest) {
        tracing::warn!(%error, "bridge watcher: failed to publish manifest update");
    }
}

fn create_manifest_watcher(
    event_tx: mpsc::Sender<notify::Result<notify::Event>>,
) -> Option<RecommendedWatcher> {
    RecommendedWatcher::new(
        move |result| {
            let _ = event_tx.blocking_send(result);
        },
        notify::Config::default(),
    )
    .ok()
}

fn watch_bridge_root(
    mut watcher: RecommendedWatcher,
    daemon_root: &Path,
) -> Option<RecommendedWatcher> {
    watcher
        .watch(daemon_root, RecursiveMode::NonRecursive)
        .ok()?;
    Some(watcher)
}
