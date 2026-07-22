use std::process::id as process_id;
use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::{broadcast, watch as tokio_watch};
use tokio::task::JoinHandle;

use crate::agents::acp::probe::schedule_probe_cache_refresh;
use crate::daemon::agent_acp::AcpAgentManagerHandle;
use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::http::{self, AsyncDaemonDbSlot, DaemonHttpAuthMode, DaemonHttpState};
use crate::daemon::remote_acme::RemoteAcmeRuntimePlan;
use crate::daemon::remote_acme_renewal::spawn_remote_acme_renewal_loop;
use crate::daemon::remote_tls::{RemoteTlsConfigError, RemoteTlsConfigHandle, RemoteTlsListener};
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
    shutdown_tx: tokio_watch::Sender<bool>,
    shutdown_rx: tokio_watch::Receiver<bool>,
) -> Result<(), CliError> {
    let remote_request_limits = build_remote_request_limits(&config)?;
    prepare_remote_daemon_environment(&config)?;
    let daemon_lock = state::acquire_singleton_lock()?;

    let (tls_config, listener) =
        prepare_remote_tls_listener(&config, &acme_plan, &remote_request_limits).await?;
    let (endpoint, manifest) = prepare_remote_daemon_manifest(&acme_plan, config.sandboxed)?;

    let (sender, _) = broadcast::channel(256);
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
    let replay_buffer = Arc::new(Mutex::new(ReplayBuffer::new(512)));
    let prepared_sender = background_tasks::spawn_broadcast_fanout(&sender, &replay_buffer);
    let daemon_epoch = manifest.started_at.clone();
    let async_db_slot_for_audit = async_db.clone();

    initialize_startup_state(&db, &async_db, sender.clone(), config.poll_interval).await?;
    super::audit::record_remote_daemon_bound(async_db.get(), &endpoint, config.sandboxed).await;
    schedule_probe_cache_refresh();
    let remote_acme_renewal = start_remote_acme_renewal(&db, tls_config, shutdown_rx.clone())?;

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
        remote_request_limits: Some(remote_request_limits),
        remote_pairing_limiter: http::default_remote_pairing_limiter(),
        remote_pairing_status_limiter: http::default_remote_pairing_status_limiter(),
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
    if let Some(async_db) = app_state.async_db.get() {
        Box::pin(
            super::recover_remote_assignments_at_startup_with_controller(&app_state, async_db),
        )
        .await?;
    }
    app_state
        .codex_controller
        .reconcile_task_board_admission_workers_after_restart()
        .await?;
    let _background = spawn_background_tasks(&app_state, config.poll_interval, shutdown_rx.clone());

    let serve_result = http::serve(listener, app_state, shutdown_rx).await;
    let _ = shutdown_tx.send(true);
    let renewal_result = remote_acme_renewal.await.map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "join remote ACME renewal loop: {error}"
        )))
    });
    super::audit::record_daemon_stopped(async_db_slot_for_audit.get(), &serve_result).await;
    let stop_event_result = if serve_result.is_ok() {
        state::append_event("info", "remote daemon stopped")
    } else {
        Ok(())
    };
    drop(daemon_lock);

    match (serve_result, renewal_result, stop_event_result) {
        (Err(error), _, _) | (Ok(()), Err(error), _) | (Ok(()), Ok(()), Err(error)) => Err(error),
        (Ok(()), Ok(()), Ok(())) => Ok(()),
    }
}

fn prepare_remote_daemon_environment(config: &DaemonServeConfig) -> Result<(), CliError> {
    super::super::log_sandbox_startup(config.sandboxed);
    run_startup_sweep();

    let legacy_migration_report = state::migrate_legacy_daemon_root_for_current_process()?;
    log_legacy_daemon_root_migration(&legacy_migration_report);
    state::ensure_daemon_dirs()?;
    cleanup_abandoned_sessions()?;
    Ok(())
}

async fn prepare_remote_tls_listener(
    config: &DaemonServeConfig,
    acme_plan: &RemoteAcmeRuntimePlan,
    remote_request_limits: &http::RemoteRequestLimits,
) -> Result<(RemoteTlsConfigHandle, RemoteTlsListener), CliError> {
    let tls_config = RemoteTlsConfigHandle::new(acme_plan.certificate().clone())
        .map_err(|error| remote_tls_config_cli_error(&error))?;
    let request_limit_config = remote_request_limits.config();
    tracing::info!(
        tls_generation = tls_config.generation(),
        certificate_fingerprint = %tls_config.certificate_fingerprint(),
        "remote TLS certificate loaded",
    );
    let listener = bind_remote_tls_listener(config, &tls_config, request_limit_config).await?;
    Ok((tls_config, listener))
}

fn prepare_remote_daemon_manifest(
    acme_plan: &RemoteAcmeRuntimePlan,
    sandboxed: bool,
) -> Result<(String, DaemonManifest), CliError> {
    let endpoint = acme_plan.public_https_origin();
    let manifest = remote_daemon_manifest(&endpoint, sandboxed);
    state::append_event("info", &remote_bound_event_message(&endpoint))?;
    Ok((endpoint, manifest))
}

fn build_remote_request_limits(
    config: &DaemonServeConfig,
) -> Result<http::RemoteRequestLimits, CliError> {
    validate_remote_https_config(config)?;
    let request_limits = config.remote_request_limits.ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_parse(
            "remote HTTPS serve requires request limits",
        ))
    })?;
    http::RemoteRequestLimits::new(request_limits)
}

async fn bind_remote_tls_listener(
    config: &DaemonServeConfig,
    tls_config: &RemoteTlsConfigHandle,
    limits: http::RemoteRequestLimitConfig,
) -> Result<RemoteTlsListener, CliError> {
    RemoteTlsListener::bind_reloadable_with_limits(
        (config.host.as_str(), config.port),
        tls_config,
        limits.max_concurrent_tls_handshakes,
        limits.tls_handshake_timeout,
    )
    .await
    .map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "bind remote HTTPS listener: {error}"
        )))
    })
}

fn start_remote_acme_renewal(
    db: &Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    tls: RemoteTlsConfigHandle,
    shutdown_rx: tokio_watch::Receiver<bool>,
) -> Result<JoinHandle<()>, CliError> {
    let renewal_db = db.get().cloned().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "remote ACME renewal database was not initialized",
        ))
    })?;
    Ok(spawn_remote_acme_renewal_loop(renewal_db, tls, shutdown_rx))
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
    let request_limits = config.remote_request_limits.ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_parse(
            "remote HTTPS serve requires request limits",
        ))
    })?;
    request_limits.validate()?;
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

fn remote_bound_event_message(endpoint: &str) -> String {
    format!("remote daemon bound HTTPS socket for {endpoint}")
}

#[cfg(test)]
fn remote_audit_bound_summary(endpoint: &str) -> String {
    super::audit::remote_daemon_bound_summary(endpoint)
}

#[cfg(test)]
mod tests {
    use crate::daemon::http::{DaemonHttpAuthMode, RemoteRequestLimitConfig};
    use crate::daemon::service::DaemonServeConfig;

    use super::{
        remote_audit_bound_summary, remote_bound_event_message, validate_remote_https_config,
    };

    #[test]
    fn remote_bound_event_message_does_not_claim_service_is_listening() {
        let message = remote_bound_event_message("https://daemon.example.com");

        assert!(message.contains("https://daemon.example.com"));
        assert!(!message.contains("listening"));
    }

    #[test]
    fn remote_audit_bound_summary_does_not_claim_service_is_listening() {
        let summary = remote_audit_bound_summary("https://daemon.example.com");

        assert!(summary.contains("https://daemon.example.com"));
        assert!(summary.contains("bound HTTPS socket"));
        assert!(!summary.contains("listening"));
    }

    #[test]
    fn validate_remote_https_config_requires_remote_auth_mode() {
        let config = DaemonServeConfig {
            remote_domain: Some("daemon.example.com".to_string()),
            ..DaemonServeConfig::default()
        };
        let error = validate_remote_https_config(&config)
            .expect_err("remote HTTPS should reject local auth mode");

        assert!(
            error
                .to_string()
                .contains("requires remote authentication mode")
        );
    }

    #[test]
    fn validate_remote_https_config_requires_remote_domain() {
        let config = DaemonServeConfig {
            auth_mode: DaemonHttpAuthMode::Remote,
            remote_domain: Some("   ".to_string()),
            ..DaemonServeConfig::default()
        };
        let error = validate_remote_https_config(&config)
            .expect_err("remote HTTPS should reject blank domain");

        assert!(error.to_string().contains("requires a remote domain"));
    }

    #[test]
    fn validate_remote_https_config_requires_request_limits() {
        let config = DaemonServeConfig {
            auth_mode: DaemonHttpAuthMode::Remote,
            remote_domain: Some("daemon.example.com".to_string()),
            ..DaemonServeConfig::default()
        };
        let error = validate_remote_https_config(&config)
            .expect_err("remote HTTPS should reject missing request limits");

        assert!(error.to_string().contains("request limits"));
    }

    #[test]
    fn validate_remote_https_config_rejects_disabled_request_limits() {
        let config = DaemonServeConfig {
            auth_mode: DaemonHttpAuthMode::Remote,
            remote_domain: Some("daemon.example.com".to_string()),
            remote_request_limits: Some(RemoteRequestLimitConfig {
                max_http_concurrency: 0,
                ..RemoteRequestLimitConfig::default()
            }),
            ..DaemonServeConfig::default()
        };
        let error = validate_remote_https_config(&config)
            .expect_err("remote HTTPS should reject disabled request limits");

        assert!(error.to_string().contains("non-zero HTTP concurrency"));
    }

    #[test]
    fn validate_remote_https_config_accepts_remote_auth_and_domain() {
        let config = DaemonServeConfig {
            auth_mode: DaemonHttpAuthMode::Remote,
            remote_domain: Some("daemon.example.com".to_string()),
            remote_request_limits: Some(RemoteRequestLimitConfig::default()),
            ..DaemonServeConfig::default()
        };

        validate_remote_https_config(&config).expect("valid remote HTTPS config");
    }
}
