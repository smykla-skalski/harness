use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use tokio::sync::watch as tokio_watch;
use tokio::task::{JoinHandle, spawn_blocking};
use tokio::time::{MissedTickBehavior, interval};
use uuid::Uuid;

use super::db::DaemonDb;
use super::remote::{RemoteAccessScope, RemoteDaemonServeConfig};
use super::remote_acme::{
    RemoteAcmeAccountCredentials, RemoteAcmeRenewalIssuer, RemoteAcmeRenewalRequest,
    RemoteCertificateBundle, RemoteRenewalOutcome, build_remote_acme_runtime_plan,
};
use super::remote_acme_live::LiveRemoteAcmeIssuer;
use super::remote_certificate_identity::{RemoteCertificateIdentityError, certificate_not_after};
use super::remote_identity::{RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision};
use super::remote_tls::{RemoteTlsConfigHandle, build_remote_tls_server_config};
use crate::errors::{CliError, CliErrorKind};

const REMOTE_ACME_RENEWAL_WINDOW: ChronoDuration = ChronoDuration::days(30);
const REMOTE_ACME_CHECK_INTERVAL: Duration = Duration::from_hours(1);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemoteAcmeRenewalCheckOutcome {
    NotDue,
    Reloaded,
    Renewed,
    Failed,
}

struct RemoteAcmeRenewalSnapshot {
    config: RemoteDaemonServeConfig,
    account: RemoteAcmeAccountCredentials,
    bundle: RemoteCertificateBundle,
    previous_private_key_pem: Option<String>,
}

pub(crate) fn remote_certificate_needs_renewal(
    bundle: &RemoteCertificateBundle,
    now: DateTime<Utc>,
) -> Result<bool, RemoteCertificateIdentityError> {
    let renew_at = certificate_not_after(bundle)? - REMOTE_ACME_RENEWAL_WINDOW;
    Ok(now >= renew_at)
}

pub(crate) fn spawn_remote_acme_renewal_loop(
    db: Arc<Mutex<DaemonDb>>,
    tls: RemoteTlsConfigHandle,
    shutdown_rx: tokio_watch::Receiver<bool>,
) -> JoinHandle<()> {
    let issuer = Arc::new(LiveRemoteAcmeIssuer::new(tls.clone()));
    spawn_remote_acme_renewal_loop_with(
        db,
        tls,
        issuer,
        shutdown_rx,
        REMOTE_ACME_CHECK_INTERVAL,
        Utc::now,
    )
}

pub(crate) fn spawn_remote_acme_renewal_loop_with<I, Now>(
    db: Arc<Mutex<DaemonDb>>,
    tls: RemoteTlsConfigHandle,
    issuer: Arc<I>,
    shutdown_rx: tokio_watch::Receiver<bool>,
    check_interval: Duration,
    now: Now,
) -> JoinHandle<()>
where
    I: RemoteAcmeRenewalIssuer + Send + Sync + 'static,
    Now: Fn() -> DateTime<Utc> + Send + Sync + 'static,
{
    tokio::spawn(run_remote_acme_renewal_loop(
        db,
        tls,
        issuer,
        shutdown_rx,
        check_interval,
        Arc::new(now),
    ))
}

async fn run_remote_acme_renewal_loop<I, Now>(
    db: Arc<Mutex<DaemonDb>>,
    tls: RemoteTlsConfigHandle,
    issuer: Arc<I>,
    mut shutdown_rx: tokio_watch::Receiver<bool>,
    check_interval: Duration,
    now: Arc<Now>,
) where
    I: RemoteAcmeRenewalIssuer + Send + Sync + 'static,
    Now: Fn() -> DateTime<Utc> + Send + Sync + 'static,
{
    let mut ticker = interval(check_interval);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            () = wait_for_shutdown(&mut shutdown_rx) => break,
            _ = ticker.tick() => {
                let result = run_remote_acme_renewal_check_blocking(
                    Arc::clone(&db),
                    tls.clone(),
                    Arc::clone(&issuer),
                    Arc::clone(&now),
                ).await;
                log_renewal_check(&result);
            }
        }
    }
}

async fn wait_for_shutdown(shutdown_rx: &mut tokio_watch::Receiver<bool>) {
    if *shutdown_rx.borrow() {
        return;
    }
    while shutdown_rx.changed().await.is_ok() {
        if *shutdown_rx.borrow() {
            break;
        }
    }
}

async fn run_remote_acme_renewal_check_blocking<I, Now>(
    db: Arc<Mutex<DaemonDb>>,
    tls: RemoteTlsConfigHandle,
    issuer: Arc<I>,
    now: Arc<Now>,
) -> Result<RemoteAcmeRenewalCheckOutcome, CliError>
where
    I: RemoteAcmeRenewalIssuer + Send + Sync + 'static,
    Now: Fn() -> DateTime<Utc> + Send + Sync + 'static,
{
    spawn_blocking(move || run_remote_acme_renewal_check(&db, &tls, issuer.as_ref(), now()))
        .await
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "join remote ACME renewal check: {error}"
            )))
        })?
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_renewal_check(result: &Result<RemoteAcmeRenewalCheckOutcome, CliError>) {
    match result {
        Ok(RemoteAcmeRenewalCheckOutcome::NotDue) => {
            tracing::debug!("remote ACME certificate is outside the renewal window");
        }
        Ok(RemoteAcmeRenewalCheckOutcome::Reloaded) => {
            tracing::info!("remote TLS certificate reloaded from persisted ACME state");
        }
        Ok(RemoteAcmeRenewalCheckOutcome::Renewed) => {
            tracing::info!("remote ACME certificate renewed and reloaded");
        }
        Ok(RemoteAcmeRenewalCheckOutcome::Failed) => {
            tracing::warn!("remote ACME automatic renewal failed; status was persisted");
        }
        Err(error) => {
            tracing::warn!(%error, "remote ACME automatic renewal check failed");
        }
    }
}

pub(crate) fn run_remote_acme_renewal_check<I>(
    db: &Arc<Mutex<DaemonDb>>,
    tls: &RemoteTlsConfigHandle,
    issuer: &I,
    now: DateTime<Utc>,
) -> Result<RemoteAcmeRenewalCheckOutcome, CliError>
where
    I: RemoteAcmeRenewalIssuer,
{
    let snapshot = load_renewal_snapshot(db)?;
    let due = remote_certificate_needs_renewal(&snapshot.bundle, now).unwrap_or(true);
    if !due && tls.certificate_fingerprint() == snapshot.bundle.fingerprint() {
        return Ok(RemoteAcmeRenewalCheckOutcome::NotDue);
    }
    if !due && tls.reload(snapshot.bundle.clone()).is_ok() {
        record_automatic_audit(
            db,
            now,
            "remote.tls.reload.automatic",
            RemoteAuditOutcome::Success,
            None,
        )?;
        return Ok(RemoteAcmeRenewalCheckOutcome::Reloaded);
    }
    renew_due_certificate(db, tls, issuer, &snapshot, now)
}

fn load_renewal_snapshot(db: &Arc<Mutex<DaemonDb>>) -> Result<RemoteAcmeRenewalSnapshot, CliError> {
    let db = lock_db(db)?;
    let stored = db.load_remote_acme_state()?;
    let config = stored.serve_config.ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_parse(
            "remote automatic renewal requires persisted ACME serve config",
        ))
    })?;
    let issuance = db.load_remote_acme_issuance_state()?;
    let account = issuance.account.ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_parse(
            "remote automatic renewal requires persisted ACME account credentials",
        ))
    })?;
    let runtime_state = db.load_remote_acme_runtime_state()?;
    let plan = build_remote_acme_runtime_plan(&config, &runtime_state)
        .map_err(|error| CliError::from(CliErrorKind::workflow_parse(error.to_string())))?;
    Ok(RemoteAcmeRenewalSnapshot {
        config,
        account,
        bundle: plan.certificate().clone(),
        previous_private_key_pem: issuance.previous_private_key_pem,
    })
}

fn renew_due_certificate<I>(
    db: &Arc<Mutex<DaemonDb>>,
    tls: &RemoteTlsConfigHandle,
    issuer: &I,
    snapshot: &RemoteAcmeRenewalSnapshot,
    now: DateTime<Utc>,
) -> Result<RemoteAcmeRenewalCheckOutcome, CliError>
where
    I: RemoteAcmeRenewalIssuer,
{
    let request = RemoteAcmeRenewalRequest::new(
        &snapshot.account,
        Some(snapshot.bundle.fingerprint()),
        snapshot.previous_private_key_pem.as_deref(),
        &snapshot.config,
    );
    let bundle = match issuer.renew_certificate(&request) {
        Ok(bundle) => bundle,
        Err(detail) => return persist_renewal_failure(db, now, &detail),
    };
    if let Err(error) = build_remote_tls_server_config(&bundle) {
        return persist_renewal_failure(
            db,
            now,
            &format!("renewed remote TLS material is invalid: {error}"),
        );
    }
    if !persist_renewal_success(db, now, &bundle, snapshot)? {
        return reload_superseding_certificate(db, tls, now);
    }
    tls.reload(bundle).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "publish renewed remote TLS certificate: {error}"
        )))
    })?;
    Ok(RemoteAcmeRenewalCheckOutcome::Renewed)
}

fn persist_renewal_failure(
    db: &Arc<Mutex<DaemonDb>>,
    now: DateTime<Utc>,
    detail: &str,
) -> Result<RemoteAcmeRenewalCheckOutcome, CliError> {
    let report = RemoteRenewalOutcome::failure(detail).report().to_string();
    lock_db(db)?.record_remote_acme_renewal_failure(detail, &timestamp(now))?;
    record_automatic_audit(
        db,
        now,
        "remote.acme.renew.automatic",
        RemoteAuditOutcome::Failure,
        Some(&report),
    )?;
    Ok(RemoteAcmeRenewalCheckOutcome::Failed)
}

fn persist_renewal_success(
    db: &Arc<Mutex<DaemonDb>>,
    now: DateTime<Utc>,
    bundle: &RemoteCertificateBundle,
    snapshot: &RemoteAcmeRenewalSnapshot,
) -> Result<bool, CliError> {
    let persisted = lock_db(db)?.record_remote_acme_renewal_success_if_current(
        bundle,
        snapshot.bundle.fingerprint(),
        snapshot.account.account_id(),
        &snapshot.config,
        &timestamp(now),
    )?;
    let route = if persisted {
        "remote.acme.renew.automatic"
    } else {
        "remote.acme.renew.automatic.superseded"
    };
    record_automatic_audit(db, now, route, RemoteAuditOutcome::Success, None)?;
    Ok(persisted)
}

fn reload_superseding_certificate(
    db: &Arc<Mutex<DaemonDb>>,
    tls: &RemoteTlsConfigHandle,
    now: DateTime<Utc>,
) -> Result<RemoteAcmeRenewalCheckOutcome, CliError> {
    let latest = load_renewal_snapshot(db)?;
    tls.reload(latest.bundle).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "publish superseding remote TLS certificate: {error}"
        )))
    })?;
    record_automatic_audit(
        db,
        now,
        "remote.tls.reload.automatic",
        RemoteAuditOutcome::Success,
        None,
    )?;
    Ok(RemoteAcmeRenewalCheckOutcome::Reloaded)
}

fn record_automatic_audit(
    db: &Arc<Mutex<DaemonDb>>,
    now: DateTime<Utc>,
    route_or_method: &str,
    outcome: RemoteAuditOutcome,
    error_detail: Option<&str>,
) -> Result<(), CliError> {
    lock_db(db)?.record_remote_audit_event(&RemoteAuditEvent::new(
        format!("remote-acme-auto-{}", Uuid::new_v4()),
        timestamp(now),
        None,
        None,
        route_or_method,
        RemoteAccessScope::Admin,
        RemoteAuditScopeDecision::Allowed,
        outcome,
        None,
        error_detail,
    ))
}

fn timestamp(now: DateTime<Utc>) -> String {
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn lock_db(db: &Arc<Mutex<DaemonDb>>) -> Result<MutexGuard<'_, DaemonDb>, CliError> {
    db.lock().map_err(|error| {
        CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}")).into()
    })
}

#[cfg(test)]
#[path = "remote_acme_renewal_tests.rs"]
mod tests;
