use std::future::Future;
use std::time::Duration;

use async_trait::async_trait;
use tokio::sync::watch as tokio_watch;
use tokio::time::timeout;

use crate::daemon::db::DaemonDb;
use crate::daemon::remote::RemoteDaemonServeConfig;
use crate::daemon::remote_acme::{
    RemoteAcmeAccountCredentials, RemoteAcmeRenewalRequest, RemoteCertificateBundle,
};
use crate::daemon::remote_acme_cleanup::RemoteAcmeCleanupTracker;
use crate::daemon::remote_acme_issuer::SystemRemoteAcmeIssuer;
use crate::daemon::remote_identity::RemoteAuditOutcome;
use crate::errors::{CliError, CliErrorKind};

use super::remote_acme::record_remote_acme_audit;

const INITIAL_ACME_CLEANUP_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemoteInitialAcmeControl {
    Continue,
    ShutdownDuringIssuance,
    ShutdownAfterIssuance,
}

#[async_trait]
pub(crate) trait RemoteInitialAcmeIssuer: Sync {
    async fn create_account(
        &self,
        config: &RemoteDaemonServeConfig,
    ) -> Result<RemoteAcmeAccountCredentials, String>;

    async fn renew_certificate(
        &self,
        request: &RemoteAcmeRenewalRequest,
        cleanup_tracker: &RemoteAcmeCleanupTracker,
    ) -> Result<RemoteCertificateBundle, String>;
}

#[async_trait]
impl RemoteInitialAcmeIssuer for SystemRemoteAcmeIssuer {
    async fn create_account(
        &self,
        config: &RemoteDaemonServeConfig,
    ) -> Result<RemoteAcmeAccountCredentials, String> {
        self.create_account_async(config).await
    }

    async fn renew_certificate(
        &self,
        request: &RemoteAcmeRenewalRequest,
        cleanup_tracker: &RemoteAcmeCleanupTracker,
    ) -> Result<RemoteCertificateBundle, String> {
        self.renew_certificate_async(request, cleanup_tracker.clone())
            .await
    }
}

pub(crate) async fn ensure_initial_remote_acme<I>(
    db: &DaemonDb,
    issuer: &I,
    now: &str,
    certificate_domain_matches: bool,
    cleanup_tracker: &RemoteAcmeCleanupTracker,
) -> Result<(), CliError>
where
    I: RemoteInitialAcmeIssuer,
{
    let state = db.load_remote_acme_state()?;
    let issuance = db.load_remote_acme_issuance_state()?;
    if state.certificate_configured && issuance.account.is_some() && certificate_domain_matches {
        return Ok(());
    }
    let audit_event_id = format!("remote-acme-initial-{}", uuid::Uuid::new_v4());
    let Some(serve_config) = state.serve_config.as_ref() else {
        return record_initial_acme_failure(
            db,
            &audit_event_id,
            now,
            "remote daemon requires persisted remote ACME serve config",
        );
    };
    let account = match issuance.account {
        Some(account) => account,
        None => match issuer.create_account(serve_config).await {
            Ok(account) => {
                db.record_remote_acme_account(&account, now)?;
                account
            }
            Err(detail) => {
                return record_initial_acme_failure(db, &audit_event_id, now, &detail);
            }
        },
    };
    let request = RemoteAcmeRenewalRequest::new(
        &account,
        state.certificate_fingerprint.as_deref(),
        issuance.previous_private_key_pem.as_deref(),
        serve_config,
    );
    match issuer.renew_certificate(&request, cleanup_tracker).await {
        Ok(bundle) => {
            db.record_remote_acme_renewal_success(&bundle, now)?;
            record_remote_acme_audit(
                db,
                &audit_event_id,
                now,
                "remote.acme.renew",
                RemoteAuditOutcome::Success,
                None,
            )
        }
        Err(detail) => record_initial_acme_failure(db, &audit_event_id, now, &detail),
    }
}

pub(crate) fn record_initial_acme_shutdown(db: &DaemonDb, now: &str) -> Result<(), CliError> {
    let audit_event_id = format!("remote-acme-initial-{}", uuid::Uuid::new_v4());
    record_initial_acme_failure_detail(
        db,
        &audit_event_id,
        now,
        "remote ACME initial issuance cancelled during daemon shutdown",
    )?;
    Ok(())
}

fn record_initial_acme_failure(
    db: &DaemonDb,
    audit_event_id: &str,
    now: &str,
    detail: &str,
) -> Result<(), CliError> {
    let redacted_detail = record_initial_acme_failure_detail(db, audit_event_id, now, detail)?;
    Err(CliErrorKind::workflow_parse(redacted_detail).into())
}

fn record_initial_acme_failure_detail(
    db: &DaemonDb,
    audit_event_id: &str,
    now: &str,
    detail: &str,
) -> Result<String, CliError> {
    db.record_remote_acme_renewal_failure(detail, now)?;
    let state = db.load_remote_acme_state()?;
    let redacted_detail = state
        .renewal_error
        .as_deref()
        .unwrap_or("remote ACME initial issuance failed")
        .to_string();
    record_remote_acme_audit(
        db,
        audit_event_id,
        now,
        "remote.acme.renew",
        RemoteAuditOutcome::Failure,
        Some(&redacted_detail),
    )?;
    Ok(redacted_detail)
}

pub(crate) async fn run_initial_acme_until_shutdown<F>(
    mut shutdown_rx: tokio_watch::Receiver<bool>,
    cleanup_tracker: &RemoteAcmeCleanupTracker,
    initial_acme: F,
) -> Result<RemoteInitialAcmeControl, CliError>
where
    F: Future<Output = Result<(), CliError>>,
{
    let outcome = {
        tokio::pin!(initial_acme);
        tokio::select! {
            () = wait_for_shutdown(&mut shutdown_rx) => None,
            result = &mut initial_acme => Some(result),
        }
    };
    initial_acme_control(outcome, &shutdown_rx, cleanup_tracker).await
}

async fn initial_acme_control(
    outcome: Option<Result<(), CliError>>,
    shutdown_rx: &tokio_watch::Receiver<bool>,
    cleanup_tracker: &RemoteAcmeCleanupTracker,
) -> Result<RemoteInitialAcmeControl, CliError> {
    if let Some(result) = outcome {
        result?;
        if *shutdown_rx.borrow() {
            wait_for_cleanup(cleanup_tracker).await;
            Ok(RemoteInitialAcmeControl::ShutdownAfterIssuance)
        } else {
            Ok(RemoteInitialAcmeControl::Continue)
        }
    } else {
        wait_for_cleanup(cleanup_tracker).await;
        Ok(RemoteInitialAcmeControl::ShutdownDuringIssuance)
    }
}

async fn wait_for_shutdown(shutdown_rx: &mut tokio_watch::Receiver<bool>) {
    if *shutdown_rx.borrow() {
        return;
    }
    while shutdown_rx.changed().await.is_ok() {
        if *shutdown_rx.borrow() {
            return;
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
async fn wait_for_cleanup(cleanup_tracker: &RemoteAcmeCleanupTracker) {
    if timeout(
        INITIAL_ACME_CLEANUP_TIMEOUT,
        cleanup_tracker.wait_for_cleanup(),
    )
    .await
    .is_err()
    {
        tracing::warn!("remote ACME challenge cleanup timed out during initial shutdown");
    }
}
