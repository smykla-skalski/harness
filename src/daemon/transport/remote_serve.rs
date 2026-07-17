use std::thread;

use crate::daemon::db::DaemonDb;
use crate::daemon::remote::RemoteDaemonServeConfig;
#[cfg(test)]
use crate::daemon::remote_acme::RemoteAcmeRenewalIssuer;
use crate::daemon::remote_acme::{RemoteAcmeRuntimePlan, build_remote_acme_runtime_plan};
use crate::daemon::remote_acme_cleanup::RemoteAcmeCleanupTracker;
use crate::daemon::remote_acme_issuer::SystemRemoteAcmeIssuer;
use crate::daemon::service::{self, DaemonServeConfig, ShutdownSignalGuard};
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;
use tokio::runtime::{Handle, Runtime};
use tokio::sync::watch as tokio_watch;

use super::control::adopt_daemon_root_for_transport_command;
#[cfg(test)]
use super::remote::DaemonRemoteAcmeCommand;
use super::remote::{DaemonRemoteServeArgs, open_remote_daemon_db};
use super::remote_serve_startup::{
    RemoteInitialAcmeControl, ensure_initial_remote_acme, record_initial_acme_shutdown,
    run_initial_acme_until_shutdown,
};

#[derive(Clone)]
pub(crate) struct RemoteDaemonServeExecutionPlan {
    pub(crate) service_config: DaemonServeConfig,
    pub(crate) acme_plan: RemoteAcmeRuntimePlan,
}

pub(super) fn execute_remote_serve(args: &DaemonRemoteServeArgs) -> Result<i32, CliError> {
    adopt_daemon_root_for_transport_command("daemon-remote-serve");
    let db = open_remote_daemon_db()?;
    let remote_config = args.contract_config()?;
    let certificate_domain_matches = certificate_domain_matches(&db, &remote_config)?;
    let now = utc_now();
    db.record_remote_acme_serve_config(&remote_config, now.as_str())?;
    run_remote_serve_lifecycle(
        args.clone(),
        db,
        remote_config,
        certificate_domain_matches,
        now,
    )
}

#[cfg(test)]
pub(crate) fn execute_remote_serve_with<OpenDb, Run>(
    args: &DaemonRemoteServeArgs,
    open_db: OpenDb,
    run_plan: Run,
) -> Result<i32, CliError>
where
    OpenDb: FnOnce() -> Result<DaemonDb, CliError>,
    Run: FnOnce(RemoteDaemonServeExecutionPlan) -> Result<i32, CliError>,
{
    let now = utc_now();
    execute_remote_serve_with_issuer(
        args,
        open_db,
        run_plan,
        &SystemRemoteAcmeIssuer,
        now.as_str(),
    )
}

#[cfg(test)]
pub(crate) fn execute_remote_serve_with_issuer<OpenDb, Run, Issuer>(
    args: &DaemonRemoteServeArgs,
    open_db: OpenDb,
    run_plan: Run,
    issuer: &Issuer,
    now: &str,
) -> Result<i32, CliError>
where
    OpenDb: FnOnce() -> Result<DaemonDb, CliError>,
    Run: FnOnce(RemoteDaemonServeExecutionPlan) -> Result<i32, CliError>,
    Issuer: RemoteAcmeRenewalIssuer,
{
    adopt_daemon_root_for_transport_command("daemon-remote-serve");
    let db = open_db()?;
    let remote_config = args.contract_config()?;
    let certificate_domain_matches = certificate_domain_matches(&db, &remote_config)?;
    db.record_remote_acme_serve_config(&remote_config, now)?;
    ensure_remote_acme_for_serve(&db, issuer, now, certificate_domain_matches)?;
    let plan = build_remote_serve_execution_plan_from_config(args, &db, &remote_config)?;
    run_plan(plan)
}

fn certificate_domain_matches(
    db: &DaemonDb,
    remote_config: &RemoteDaemonServeConfig,
) -> Result<bool, CliError> {
    Ok(db
        .load_remote_acme_state()?
        .serve_config
        .as_ref()
        .is_some_and(|stored| {
            stored
                .domain
                .trim()
                .eq_ignore_ascii_case(remote_config.domain.trim())
        }))
}

/// Build the remote daemon serve execution plan from static CLI config and
/// persisted ACME runtime state.
///
/// # Errors
/// Returns [`CliError`] when remote config is invalid or persisted ACME TLS
/// state is incomplete.
#[cfg(test)]
pub(crate) fn build_remote_serve_execution_plan(
    args: &DaemonRemoteServeArgs,
    db: &DaemonDb,
) -> Result<RemoteDaemonServeExecutionPlan, CliError> {
    let remote_config = args.contract_config()?;
    db.record_remote_acme_serve_config(&remote_config, utc_now().as_str())?;
    build_remote_serve_execution_plan_from_config(args, db, &remote_config)
}

fn build_remote_serve_execution_plan_from_config(
    args: &DaemonRemoteServeArgs,
    db: &DaemonDb,
    remote_config: &RemoteDaemonServeConfig,
) -> Result<RemoteDaemonServeExecutionPlan, CliError> {
    let acme_state = db.load_remote_acme_runtime_state()?;
    let acme_plan = build_remote_acme_runtime_plan(remote_config, &acme_state)
        .map_err(|error| CliError::from(CliErrorKind::workflow_parse(error.to_string())))?;
    let service_config = args.remote_auth_scaffold_config()?;
    Ok(RemoteDaemonServeExecutionPlan {
        service_config,
        acme_plan,
    })
}

#[cfg(test)]
fn ensure_remote_acme_for_serve<I>(
    db: &DaemonDb,
    issuer: &I,
    now: &str,
    certificate_domain_matches: bool,
) -> Result<(), CliError>
where
    I: RemoteAcmeRenewalIssuer,
{
    let state = db.load_remote_acme_state()?;
    let issuance = db.load_remote_acme_issuance_state()?;
    if state.certificate_configured && issuance.account.is_some() && certificate_domain_matches {
        return Ok(());
    }
    let audit_event_id = format!("remote-acme-initial-{}", uuid::Uuid::new_v4());
    DaemonRemoteAcmeCommand::Renew
        .renew_with_issuer(db, &audit_event_id, now, issuer)?
        .ensure_success()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemoteServeRuntimeMode {
    ExistingTokioRuntime,
    NewTokioRuntime,
}

pub(crate) fn remote_serve_runtime_mode() -> RemoteServeRuntimeMode {
    if Handle::try_current().is_ok() {
        RemoteServeRuntimeMode::ExistingTokioRuntime
    } else {
        RemoteServeRuntimeMode::NewTokioRuntime
    }
}

fn run_remote_serve_lifecycle(
    args: DaemonRemoteServeArgs,
    db: DaemonDb,
    remote_config: RemoteDaemonServeConfig,
    certificate_domain_matches: bool,
    now: String,
) -> Result<i32, CliError> {
    match remote_serve_runtime_mode() {
        RemoteServeRuntimeMode::ExistingTokioRuntime => run_remote_daemon_thread(move || {
            run_remote_serve_lifecycle_on_runtime(
                &args,
                &db,
                &remote_config,
                certificate_domain_matches,
                &now,
            )
        }),
        RemoteServeRuntimeMode::NewTokioRuntime => run_remote_serve_lifecycle_on_runtime(
            &args,
            &db,
            &remote_config,
            certificate_domain_matches,
            &now,
        ),
    }
}

pub(crate) fn run_remote_daemon_thread<T, Run>(run: Run) -> Result<T, CliError>
where
    T: Send,
    Run: FnOnce() -> Result<T, CliError> + Send,
{
    thread::scope(|scope| {
        thread::Builder::new()
            .name("harness-remote-daemon".to_string())
            .spawn_scoped(scope, run)
            .map_err(|error| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "spawn remote daemon lifecycle thread: {error}"
                )))
            })?
            .join()
            .map_err(|_| {
                CliError::from(CliErrorKind::workflow_io(
                    "remote daemon lifecycle thread panicked",
                ))
            })?
    })
}

fn run_remote_serve_lifecycle_on_runtime(
    args: &DaemonRemoteServeArgs,
    db: &DaemonDb,
    remote_config: &RemoteDaemonServeConfig,
    certificate_domain_matches: bool,
    now: &str,
) -> Result<i32, CliError> {
    let runtime = Runtime::new().map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "create remote daemon tokio runtime: {error}"
        )))
    })?;
    runtime.block_on(run_remote_serve_lifecycle_async(
        args,
        db,
        remote_config,
        certificate_domain_matches,
        now,
    ))
}

async fn run_remote_serve_lifecycle_async(
    args: &DaemonRemoteServeArgs,
    db: &DaemonDb,
    remote_config: &RemoteDaemonServeConfig,
    certificate_domain_matches: bool,
    now: &str,
) -> Result<i32, CliError> {
    let (shutdown_tx, shutdown_rx) = tokio_watch::channel(false);
    let _shutdown_signal_guard = ShutdownSignalGuard::install(shutdown_tx.clone())?;
    let cleanup_tracker = RemoteAcmeCleanupTracker::default();
    let initial_acme = ensure_initial_remote_acme(
        db,
        &SystemRemoteAcmeIssuer,
        now,
        certificate_domain_matches,
        &cleanup_tracker,
    );
    let control =
        run_initial_acme_until_shutdown(shutdown_rx.clone(), &cleanup_tracker, initial_acme)
            .await?;
    match control {
        RemoteInitialAcmeControl::Continue => {}
        RemoteInitialAcmeControl::ShutdownDuringIssuance => {
            record_initial_acme_shutdown(db, utc_now().as_str())?;
            return Ok(0);
        }
        RemoteInitialAcmeControl::ShutdownAfterIssuance => return Ok(0),
    }
    let plan = build_remote_serve_execution_plan_from_config(args, db, remote_config)?;
    // Boxing keeps the long-lived HTTPS future below the denied large-futures threshold.
    Box::pin(service::serve_remote_https(
        plan.service_config,
        plan.acme_plan,
        shutdown_tx,
        shutdown_rx,
    ))
    .await?;
    Ok(0)
}
