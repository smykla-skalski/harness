use std::process::id as process_id;
use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::{broadcast, watch as tokio_watch};

use crate::agents::acp::probe::schedule_probe_cache_refresh;
use crate::daemon::agent_acp::AcpAgentManagerHandle;
use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::http::{self, AsyncDaemonDbSlot, DaemonHttpAuthMode, DaemonHttpState};
use crate::daemon::remote_acme::RemoteAcmeRuntimePlan;
use crate::daemon::remote_tls::{
    RemoteTlsConfigError, RemoteTlsListener, build_remote_tls_server_config,
};
use crate::daemon::state::{self, DaemonManifest, HostBridgeManifest};
use crate::daemon::voice::cleanup_abandoned_sessions;
use crate::daemon::websocket::ReplayBuffer;
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::orphan_cleanup::run_startup_sweep;
use crate::workspace::utc_now;

use super::super::{DaemonObserveRuntime, DaemonServeConfig, OBSERVE_RUNTIME, SHUTDOWN_SIGNAL};
use super::background_tasks::{self, spawn_background_tasks};
use super::binary_stamp::current_binary_stamp;
use super::initialize_startup_state;
use super::legacy_migration::log_legacy_daemon_root_migration;
use super::shutdown_signals::ShutdownSignalGuard;

/// Start the remote daemon HTTPS API.
///
/// # Errors
/// Returns [`CliError`] if remote auth/TLS preflight fails or the HTTPS server
/// cannot bind.
#[expect(
    clippy::cognitive_complexity,
    reason = "remote serve wires startup, runtime, and teardown in one lifecycle path"
)]
pub async fn serve_remote_https(
    config: DaemonServeConfig,
    acme_plan: RemoteAcmeRuntimePlan,
) -> Result<(), CliError> {
    validate_remote_https_config(&config)?;
    super::super::log_sandbox_startup(config.sandboxed);
    run_startup_sweep();

    let legacy_migration_report = state::migrate_legacy_daemon_root_for_current_process()?;
    log_legacy_daemon_root_migration(&legacy_migration_report);
    state::ensure_daemon_dirs()?;
    cleanup_abandoned_sessions()?;
    let daemon_lock = state::acquire_singleton_lock()?;

    let tls_config = build_remote_tls_server_config(acme_plan.certificate())
        .map_err(|error| remote_tls_config_cli_error(&error))?;
    let listener = RemoteTlsListener::bind((config.host.as_str(), config.port), tls_config)
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("bind remote HTTPS listener: {error}"))
        })?;
    let endpoint = acme_plan.public_https_origin();
    let manifest = remote_daemon_manifest(&endpoint, config.sandboxed);
    state::append_event("info", &format!("remote daemon listening on {endpoint}"))?;

    let (sender, _) = broadcast::channel(256);
    let (shutdown_tx, shutdown_rx) = tokio_watch::channel(false);
    let db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>> = Arc::new(OnceLock::new());
    let async_db: Arc<OnceLock<Arc<AsyncDaemonDb>>> = Arc::new(OnceLock::new());
    let _ = OBSERVE_RUNTIME.set(DaemonObserveRuntime {
        sender: sender.clone(),
        poll_interval: config.observe_interval,
        running_sessions: Arc::default(),
        db: db.clone(),
        async_db: async_db.clone(),
    });
    let _ = SHUTDOWN_SIGNAL.set(shutdown_tx.clone());
    let _shutdown_signal_guard = ShutdownSignalGuard::install(shutdown_tx.clone())?;
    let replay_buffer = Arc::new(Mutex::new(ReplayBuffer::new(512)));
    let prepared_sender = background_tasks::spawn_broadcast_fanout(&sender, &replay_buffer);
    let daemon_epoch = manifest.started_at.clone();
    let async_db_slot_for_audit = async_db.clone();

    initialize_startup_state(&db, &async_db, sender.clone(), config.poll_interval).await?;
    super::audit::record_daemon_started(async_db.get(), &endpoint, config.sandboxed).await;
    schedule_probe_cache_refresh();

    let codex_controller = CodexControllerHandle::new_with_async_db(
        sender.clone(),
        db.clone(),
        async_db.clone(),
        config.sandboxed,
    );
    let agent_tui_manager = AgentTuiManagerHandle::new_with_async_db(
        sender.clone(),
        db.clone(),
        async_db.clone(),
        config.sandboxed,
    );
    let acp_agent_manager =
        AcpAgentManagerHandle::new_with_async_db(sender.clone(), db.clone(), async_db.clone());
    let app_state = DaemonHttpState {
        token: String::new(),
        auth_mode: config.auth_mode,
        remote_domain: config.remote_domain.clone(),
        remote_pairing_limiter: http::default_remote_pairing_limiter(),
        sender,
        prepared_sender,
        manifest,
        daemon_epoch,
        replay_buffer,
        db,
        async_db: AsyncDaemonDbSlot::from_inner(async_db),
        db_path: Some(state::daemon_root().join("harness.db")),
        codex_controller,
        agent_tui_manager,
        acp_agent_manager,
        managed_agent_mutation_locks: http::ManagedAgentMutationLocks::default(),
        recovery_snapshot: Arc::default(),
    };
    let _background = spawn_background_tasks(&app_state, config.poll_interval, shutdown_rx.clone());

    let serve_result = http::serve(listener, app_state, shutdown_rx).await;
    super::audit::record_daemon_stopped(async_db_slot_for_audit.get(), &serve_result).await;
    let stop_event_result = if serve_result.is_ok() {
        state::append_event("info", "remote daemon stopped")
    } else {
        Ok(())
    };
    drop(daemon_lock);

    match (serve_result, stop_event_result) {
        (Err(error), _) | (Ok(()), Err(error)) => Err(error),
        (Ok(()), Ok(())) => Ok(()),
    }
}

fn validate_remote_https_config(config: &DaemonServeConfig) -> Result<(), CliError> {
    if config.auth_mode != DaemonHttpAuthMode::Remote {
        return Err(CliErrorKind::workflow_parse(
            "remote HTTPS serve requires remote authentication mode",
        )
        .into());
    }
    if config
        .remote_domain
        .as_deref()
        .unwrap_or_default()
        .trim()
        .is_empty()
    {
        return Err(
            CliErrorKind::workflow_parse("remote HTTPS serve requires a remote domain").into(),
        );
    }
    Ok(())
}

fn remote_daemon_manifest(endpoint: &str, sandboxed: bool) -> DaemonManifest {
    let now = utc_now();
    DaemonManifest {
        version: env!("CARGO_PKG_VERSION").to_string(),
        pid: process_id(),
        endpoint: endpoint.to_string(),
        started_at: now.clone(),
        token_path: String::new(),
        sandboxed,
        host_bridge: HostBridgeManifest::default(),
        revision: 0,
        updated_at: now,
        binary_stamp: current_binary_stamp(),
        ownership: state::DaemonOwnership::from_env_or_default(),
    }
}

fn remote_tls_config_cli_error(error: &RemoteTlsConfigError) -> CliError {
    CliErrorKind::workflow_parse(format!("build remote TLS config: {error}")).into()
}
