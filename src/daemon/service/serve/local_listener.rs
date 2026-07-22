use super::super::{CliError, CliErrorKind, DaemonServeConfig, TcpListener, log_sandbox_startup};
use super::legacy_migration::log_legacy_daemon_root_migration;
use super::manifest::build_manifest;
use crate::daemon::state::{self, DaemonManifest};
use crate::daemon::voice::cleanup_abandoned_sessions;
use crate::workspace::orphan_cleanup::run_startup_sweep;

pub(super) fn prepare_local_daemon_environment(config: &DaemonServeConfig) -> Result<(), CliError> {
    super::validate_serve_config(config)?;
    log_sandbox_startup(config.sandboxed);
    run_startup_sweep();

    let legacy_migration_report = state::migrate_legacy_daemon_root_for_current_process()?;
    log_legacy_daemon_root_migration(&legacy_migration_report);
    state::ensure_daemon_dirs()?;
    cleanup_abandoned_sessions()?;
    Ok(())
}

pub(super) async fn bind_local_listener_and_build_manifest(
    config: &DaemonServeConfig,
) -> Result<(TcpListener, String, DaemonManifest), CliError> {
    let listener = TcpListener::bind((config.host.as_str(), config.port))
        .await
        .map_err(|error| CliErrorKind::workflow_io(format!("bind daemon listener: {error}")))?;
    let local_addr = listener.local_addr().map_err(|error| {
        CliErrorKind::workflow_io(format!("read daemon listener addr: {error}"))
    })?;
    let endpoint = format!("http://{local_addr}");
    let manifest = build_manifest(&endpoint, config.sandboxed)?;
    Ok((listener, endpoint, manifest))
}
