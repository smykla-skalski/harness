mod acp_inspect_coalesce;
mod acp_inspect_publisher;
mod audit;
mod background_tasks;
mod binary_stamp;
mod config;
mod github_data_change_publisher;
mod identity;
mod legacy_migration;
mod local_listener;
mod machine_heartbeat_loop;
mod manifest;
mod open_db;
mod policy_bootstrap;
mod reconciliation;
mod remote;
mod shutdown_signals;
mod task_board_automation_startup;
mod task_board_migration;
#[cfg(test)]
pub(crate) mod test_support;

pub(crate) use shutdown_signals::ShutdownSignalGuard;

pub(crate) use config::{http_auth_mode, validate_serve_config};
pub(crate) use open_db::{open_daemon_async_db, open_daemon_db};
use reconciliation::spawn_background_reconciliation;
#[cfg(test)]
pub(crate) use reconciliation::test_gate as reconciliation_test_gate;
#[cfg(test)]
pub(crate) use reconciliation::{
    discover_background_reconciliation_inputs, prepare_background_session_import,
    prepared_session_import_required, run_background_reconciliation, session_import_required,
    sync_background_projects_and_collect_candidates,
};
pub(crate) use remote::serve_remote_https;

use super::{
    AgentTuiManagerHandle, Arc, CliError, CliErrorKind, CodexControllerHandle, DaemonHttpState,
    DaemonObserveRuntime, DaemonServeConfig, Duration, Mutex, OBSERVE_RUNTIME, OnceLock, Path,
    ReplayBuffer, SHUTDOWN_SIGNAL, SessionStatus, bridge, broadcast, http, index, process_id,
    state, tokio_watch, watch,
};
use crate::daemon::acp_probe::schedule_probe_cache_refresh;
use crate::daemon::agent_acp::AcpAgentManagerHandle;
use crate::daemon::http::AsyncDaemonDbSlot;
use crate::task_board::{install_prompt_catalog, resolve_prompt_catalog_from_env};
use crate::telemetry::current_trace_id;
pub(crate) use background_tasks::recover_remote_assignments_before_local_work;
use background_tasks::{
    recover_remote_assignments_at_startup_with_controller, spawn_background_tasks,
};
use local_listener::{bind_local_listener_and_build_manifest, prepare_local_daemon_environment};
use manifest::persist_manifest;
use std::time::Instant;
use tracing::Instrument as _;
use tracing::field::{Empty, display};

/// Start the daemon TCP server and service all incoming connections.
///
/// # Errors
/// Returns [`CliError`] if the server fails to start or bind.
#[expect(
    clippy::cognitive_complexity,
    reason = "daemon serve wires startup, runtime, and teardown in one lifecycle path"
)]
pub async fn serve(config: DaemonServeConfig) -> Result<(), CliError> {
    prepare_local_daemon_environment(&config)?;
    let daemon_lock = state::acquire_singleton_lock()?;
    let token = state::ensure_auth_token()?;

    let (listener, endpoint, manifest) = bind_local_listener_and_build_manifest(&config).await?;

    let (sender, _) = broadcast::channel(256);
    let (shutdown_tx, shutdown_rx) = tokio_watch::channel(false);
    let db: Arc<OnceLock<Arc<Mutex<super::db::DaemonDb>>>> = Arc::new(OnceLock::new());
    let async_db: Arc<OnceLock<Arc<super::db::AsyncDaemonDb>>> = Arc::new(OnceLock::new());
    let _ = OBSERVE_RUNTIME.set(DaemonObserveRuntime {
        sender: sender.clone(),
        poll_interval: config.observe_interval,
        running_sessions: Arc::default(),
        db: db.clone(),
        async_db: async_db.clone(),
    });
    let _ = SHUTDOWN_SIGNAL.set(shutdown_tx.clone());
    let _shutdown_signal_guard =
        shutdown_signals::ShutdownSignalGuard::install(shutdown_tx.clone())?;
    let replay_buffer = Arc::new(Mutex::new(ReplayBuffer::new(512)));
    let prepared_sender = background_tasks::spawn_broadcast_fanout(&sender, &replay_buffer);
    let daemon_epoch = manifest.started_at.clone();
    let async_db_slot_for_audit = async_db.clone();

    if let Err(error) =
        initialize_startup_state(&db, &async_db, sender.clone(), config.poll_interval).await
    {
        let _ = state::clear_manifest_for_pid(process_id());
        return Err(error);
    }
    task_board_automation_startup::initialize_control_before_serving(&async_db).await?;
    let manifest = persist_manifest(&manifest)?;
    // Only once the endpoint is discoverable. Reconciliation walks every
    // project, so awaiting it here would put that walk between the daemon
    // binding its port and the Monitor being able to find it.
    if let Some(db) = db.get() {
        spawn_background_reconciliation(db);
    }
    audit::record_daemon_started(async_db.get(), &endpoint, config.sandboxed).await;
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
    let _bridge_watcher = bridge::spawn_manifest_watcher();
    let app_state = DaemonHttpState {
        token,
        auth_mode: http_auth_mode(&config),
        remote_domain: config.remote_domain.clone(),
        remote_request_limits: None,
        companion: None,
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
    run_startup_recovery(&app_state).await?;
    let _background = spawn_background_tasks(&app_state, config.poll_interval, &shutdown_rx);

    let serve_result = http::serve(listener, app_state, shutdown_rx).await;
    audit::record_daemon_stopped(async_db_slot_for_audit.get(), &serve_result).await;
    let cleanup_result = state::clear_manifest_for_pid(process_id());
    let stop_event_result = if serve_result.is_ok() {
        state::append_event("info", "daemon stopped")
    } else {
        Ok(())
    };
    drop(daemon_lock);

    match (serve_result, cleanup_result, stop_event_result) {
        (Err(error), _, _) | (Ok(()), Err(error), _) | (Ok(()), Ok(()), Err(error)) => Err(error),
        (Ok(()), Ok(()), Ok(())) => Ok(()),
    }
}

/// Startup recovery renders prompts (it re-seals remote offers), so the catalog
/// has to be resolved before it, not with the background tasks that follow.
/// Installing it later meant recovery sealed offers with the shipped prompts
/// while everything after used the configured ones.
async fn run_startup_recovery(app_state: &DaemonHttpState) -> Result<(), CliError> {
    install_prompt_catalog(resolve_prompt_catalog_from_env());
    if let Some(async_db) = app_state.async_db.get() {
        Box::pin(recover_remote_assignments_at_startup_with_controller(
            app_state, async_db,
        ))
        .await?;
    }
    Box::pin(
        app_state
            .codex_controller
            .reconcile_task_board_admission_workers_after_restart(),
    )
    .await?;
    Ok(())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
pub(crate) fn open_and_publish_db(
    db_slot: &Arc<OnceLock<Arc<Mutex<super::db::DaemonDb>>>>,
) -> Result<Arc<Mutex<super::db::DaemonDb>>, CliError> {
    let db_path = state::daemon_root().join("harness.db");
    let db = open_daemon_db(&db_path)?;
    let db = Arc::new(Mutex::new(db));
    let _ = db_slot.set(Arc::clone(&db));
    tracing::info!("database ready");
    Ok(db)
}

pub(crate) async fn initialize_startup_state(
    db_slot: &Arc<OnceLock<Arc<Mutex<super::db::DaemonDb>>>>,
    async_db_slot: &Arc<OnceLock<Arc<super::db::AsyncDaemonDb>>>,
    sender: broadcast::Sender<super::protocol::StreamEvent>,
    poll_interval: Duration,
) -> Result<(), CliError> {
    let span = startup_span();
    if let Some(trace_id) = span.in_scope(current_trace_id) {
        span.record("trace_id", display(trace_id));
    }
    let started_at = Instant::now();
    let result = async {
        let db = open_and_publish_db(db_slot)?;
        initialize_async_db(async_db_slot).await?;
        if let Some(async_db) = async_db_slot.get() {
            task_board_migration::migrate_task_board(async_db).await?;
            reattribute_task_board_items(async_db).await;
            policy_bootstrap::bootstrap_policy_storage(async_db).await?;
        }
        spawn_startup_background_tasks(
            Arc::clone(&db),
            Arc::clone(async_db_slot),
            sender,
            poll_interval,
        );
        Ok(())
    }
    .instrument(span.clone())
    .await;

    let duration_ms = u64::try_from(started_at.elapsed().as_millis()).unwrap_or(u64::MAX);
    span.record("duration_ms", display(duration_ms));
    span.record("error", display(result.is_err()));
    if let Err(error) = &result {
        span.record("error_message", display(error));
    }

    result
}

/// Repair the items an earlier build could not attribute, before anything is
/// served from them.
///
/// A failure is logged rather than raised: the pass restores a colour mark and
/// a project-list entry, so a store that refuses it leaves the board exactly as
/// this build found it, where failing startup would take the daemon down over
/// something nobody can act on.
#[expect(
    clippy::cognitive_complexity,
    reason = "reports the outcome of reattributing unattributed task-board items; two of its three arms log, a count when some were attributed and the error on failure, while the zero case stays silent, so two macro expansions cost 14 of this 7-line function's 17 points, leaving structural 3"
)]
async fn reattribute_task_board_items(db: &super::db::AsyncDaemonDb) {
    match db.reattribute_unattributed_task_board_items().await {
        Ok(0) => {}
        Ok(count) => tracing::info!(count, "attributed task board items to their projects"),
        Err(error) => tracing::warn!(%error, "task board reattribution failed"),
    }
}

fn spawn_startup_background_tasks(
    db: Arc<Mutex<super::db::DaemonDb>>,
    async_db_slot: Arc<OnceLock<Arc<super::db::AsyncDaemonDb>>>,
    sender: broadcast::Sender<super::protocol::StreamEvent>,
    poll_interval: Duration,
) {
    let _watch = watch::spawn_watch_loop(sender, poll_interval, Some(db), async_db_slot);
    let _reviews_policy_timers =
        super::reviews::policy::spawn_reviews_policy_timer_loop(poll_interval);
    let _reviews_policy_events =
        super::reviews::policy_event_inbox::spawn_reviews_policy_event_loop(poll_interval);
}

pub(crate) async fn initialize_async_db(
    async_db_slot: &Arc<OnceLock<Arc<super::db::AsyncDaemonDb>>>,
) -> Result<(), CliError> {
    let db = open_and_publish_async_db(async_db_slot).await?;
    db.cache_startup_diagnostics().await?;
    let _ = db.health_counts().await?;
    Ok(())
}

fn startup_span() -> tracing::Span {
    tracing::info_span!(
        parent: None,
        "daemon.lifecycle.startup",
        otel.name = "daemon.lifecycle.startup",
        otel.kind = "internal",
        "daemon.phase" = "startup",
        duration_ms = Empty,
        error = Empty,
        error_message = Empty,
        trace_id = Empty
    )
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(crate) async fn open_and_publish_async_db(
    async_db_slot: &Arc<OnceLock<Arc<super::db::AsyncDaemonDb>>>,
) -> Result<Arc<super::db::AsyncDaemonDb>, CliError> {
    let db_path = state::daemon_root().join("harness.db");
    let db = Arc::new(open_daemon_async_db(&db_path).await?);
    let _ = async_db_slot.set(Arc::clone(&db));
    tracing::info!("async database pool ready");
    Ok(db)
}
