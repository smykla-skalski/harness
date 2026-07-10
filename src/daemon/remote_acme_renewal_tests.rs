use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rcgen::{CertificateParams, KeyPair, date_time_ymd};
use tokio::sync::watch;
use tokio::time::{Duration, sleep, timeout};

use super::{
    RemoteAcmeRenewalCheckOutcome, remote_certificate_needs_renewal, run_remote_acme_renewal_check,
    spawn_remote_acme_renewal_loop_with,
};
use crate::daemon::db::DaemonDb;
use crate::daemon::remote::{RemoteAcmeChallenge, RemoteDaemonServeConfig};
use crate::daemon::remote_acme::{
    RemoteAcmeAccountCredentials, RemoteAcmeAutomaticRenewalIssuer, RemoteAcmeRenewalRequest,
    RemoteCertificateBundle,
};
use crate::daemon::remote_acme_cleanup::RemoteAcmeCleanupTracker;
use crate::daemon::remote_identity::RemoteAuditOutcome;
use crate::daemon::remote_tls::RemoteTlsConfigHandle;

#[test]
fn remote_certificate_renewal_becomes_due_exactly_thirty_days_before_expiry() {
    let bundle = certificate_bundle((2026, 8, 1));
    let before = at("2026-07-01T23:59:59Z");
    let due = at("2026-07-02T00:00:00Z");

    assert!(!remote_certificate_needs_renewal(&bundle, before).expect("expiry policy"));
    assert!(remote_certificate_needs_renewal(&bundle, due).expect("expiry policy"));
}

#[tokio::test]
async fn remote_acme_renewal_check_skips_certificate_outside_renewal_window() {
    let fixture = RenewalFixture::new((2026, 9, 1));
    let issuer = FakeRenewalIssuer::succeed(certificate_bundle((2026, 12, 1)));

    let outcome = run_remote_acme_renewal_check(
        &fixture.db,
        &fixture.tls,
        &issuer,
        at("2026-07-10T00:00:00Z"),
    )
    .await
    .expect("renewal check");

    assert_eq!(outcome, RemoteAcmeRenewalCheckOutcome::NotDue);
    assert_eq!(issuer.renewal_count(), 0);
    assert_eq!(fixture.tls.generation(), 1);
}

#[tokio::test]
async fn remote_acme_renewal_check_persists_audits_and_reloads_due_certificate() {
    let fixture = RenewalFixture::new((2026, 8, 1));
    let renewed = certificate_bundle((2026, 12, 1));
    let issuer = FakeRenewalIssuer::succeed(renewed.clone());

    let outcome = run_remote_acme_renewal_check(
        &fixture.db,
        &fixture.tls,
        &issuer,
        at("2026-07-10T00:00:00Z"),
    )
    .await
    .expect("renewal check");

    assert_eq!(outcome, RemoteAcmeRenewalCheckOutcome::Renewed);
    assert_eq!(issuer.renewal_count(), 1);
    assert!(issuer.reused_previous_certificate_identity());
    assert_eq!(fixture.tls.generation(), 2);
    assert_eq!(fixture.tls.certificate_fingerprint(), renewed.fingerprint());
    let db = fixture.db.lock().expect("lock database");
    let state = db.load_remote_acme_state().expect("load ACME state");
    assert_eq!(state.renewal_status.as_str(), "succeeded");
    assert_eq!(
        state.certificate_fingerprint.as_deref(),
        Some(renewed.fingerprint())
    );
    let audits = db.load_remote_audit_events(1).expect("load audit");
    assert_eq!(audits[0].route_or_method, "remote.acme.renew.automatic");
    assert_eq!(audits[0].outcome, RemoteAuditOutcome::Success);
    assert_eq!(audits[0].error_detail, None);
}

#[tokio::test]
async fn remote_acme_renewal_check_keeps_active_certificate_and_redacts_failure() {
    let fixture = RenewalFixture::new((2026, 8, 1));
    let issuer =
        FakeRenewalIssuer::fail("provider token=renewal-secret&retry=1 secret=nested-secret");

    let outcome = run_remote_acme_renewal_check(
        &fixture.db,
        &fixture.tls,
        &issuer,
        at("2026-07-10T00:00:00Z"),
    )
    .await
    .expect("renewal check");

    assert_eq!(outcome, RemoteAcmeRenewalCheckOutcome::Failed);
    assert_eq!(issuer.renewal_count(), 1);
    assert_eq!(fixture.tls.generation(), 1);
    assert_eq!(
        fixture.tls.certificate_fingerprint(),
        fixture.initial.fingerprint()
    );
    let db = fixture.db.lock().expect("lock database");
    let state = db.load_remote_acme_state().expect("load ACME state");
    assert_eq!(state.renewal_status.as_str(), "failed");
    let report = state.renewal_error.expect("renewal failure report");
    assert!(report.contains("<redacted>"));
    assert!(!report.contains("renewal-secret"));
    assert!(!report.contains("nested-secret"));
    let audits = db.load_remote_audit_events(1).expect("load audit");
    assert_eq!(audits[0].outcome, RemoteAuditOutcome::Failure);
    assert!(
        !audits[0]
            .error_detail
            .as_deref()
            .unwrap_or_default()
            .contains("renewal-secret")
    );
}

#[tokio::test]
async fn remote_acme_renewal_check_rejects_mismatched_renewed_key_before_persisting() {
    let fixture = RenewalFixture::new((2026, 8, 1));
    let certificate_key = KeyPair::generate().expect("generate certificate key");
    let wrong_key = KeyPair::generate().expect("generate wrong key");
    let mut params =
        CertificateParams::new(["daemon.example.com".to_string()]).expect("certificate params");
    params.not_before = date_time_ymd(2026, 1, 1);
    params.not_after = date_time_ymd(2026, 12, 1);
    let certificate = params
        .self_signed(&certificate_key)
        .expect("self-sign certificate");
    let mismatched =
        RemoteCertificateBundle::new(certificate.pem().as_str(), &wrong_key.serialize_pem());
    let issuer = FakeRenewalIssuer::succeed(mismatched);

    let outcome = run_remote_acme_renewal_check(
        &fixture.db,
        &fixture.tls,
        &issuer,
        at("2026-07-10T00:00:00Z"),
    )
    .await
    .expect("renewal check");

    assert_eq!(outcome, RemoteAcmeRenewalCheckOutcome::Failed);
    assert_eq!(fixture.tls.generation(), 1);
    let state = fixture
        .db
        .lock()
        .expect("lock database")
        .load_remote_acme_state()
        .expect("load ACME state");
    assert_eq!(
        state.certificate_fingerprint.as_deref(),
        Some(fixture.initial.fingerprint())
    );
    assert!(
        state
            .renewal_error
            .as_deref()
            .is_some_and(|error| error.contains("key"))
    );
}

#[tokio::test]
async fn remote_acme_renewal_check_reloads_certificate_written_by_manual_renewal() {
    let fixture = RenewalFixture::new((2026, 9, 1));
    let externally_renewed = certificate_bundle((2026, 12, 1));
    fixture
        .db
        .lock()
        .expect("lock database")
        .record_remote_acme_renewal_success(&externally_renewed, "2026-07-10T00:00:00Z")
        .expect("persist external renewal");
    let issuer = FakeRenewalIssuer::succeed(certificate_bundle((2027, 1, 1)));

    let outcome = run_remote_acme_renewal_check(
        &fixture.db,
        &fixture.tls,
        &issuer,
        at("2026-07-10T00:01:00Z"),
    )
    .await
    .expect("renewal check");

    assert_eq!(outcome, RemoteAcmeRenewalCheckOutcome::Reloaded);
    assert_eq!(issuer.renewal_count(), 0);
    assert_eq!(fixture.tls.generation(), 2);
    assert_eq!(
        fixture.tls.certificate_fingerprint(),
        externally_renewed.fingerprint()
    );
}

#[tokio::test]
async fn remote_acme_renewal_check_does_not_overwrite_concurrent_manual_renewal() {
    let fixture = RenewalFixture::new((2026, 8, 1));
    let manually_renewed = certificate_bundle((2026, 12, 1));
    let automatic_result = certificate_bundle((2027, 1, 1));
    let issuer = ConcurrentRenewalIssuer {
        db: Arc::clone(&fixture.db),
        manually_renewed: manually_renewed.clone(),
        automatic_result,
    };

    let outcome = run_remote_acme_renewal_check(
        &fixture.db,
        &fixture.tls,
        &issuer,
        at("2026-07-10T00:00:00Z"),
    )
    .await
    .expect("renewal check");

    assert_eq!(outcome, RemoteAcmeRenewalCheckOutcome::Reloaded);
    assert_eq!(
        fixture.tls.certificate_fingerprint(),
        manually_renewed.fingerprint()
    );
    let state = fixture
        .db
        .lock()
        .expect("lock database")
        .load_remote_acme_state()
        .expect("load ACME state");
    assert_eq!(
        state.certificate_fingerprint.as_deref(),
        Some(manually_renewed.fingerprint())
    );
}

#[tokio::test]
async fn remote_acme_renewal_loop_checks_immediately_and_stops_on_shutdown() {
    let fixture = RenewalFixture::new((2026, 8, 1));
    let issuer = Arc::new(FakeRenewalIssuer::succeed(certificate_bundle((
        2026, 12, 1,
    ))));
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let task = spawn_remote_acme_renewal_loop_with(
        Arc::clone(&fixture.db),
        fixture.tls.clone(),
        Arc::clone(&issuer),
        shutdown_rx,
        Duration::from_millis(10),
        || at("2026-07-10T00:00:00Z"),
    );

    timeout(Duration::from_secs(5), async {
        while issuer.renewal_count() != 1 {
            sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("immediate renewal check timeout");

    shutdown_tx.send(true).expect("signal shutdown");
    timeout(Duration::from_secs(1), task)
        .await
        .expect("renewal loop shutdown timeout")
        .expect("renewal loop join");
    sleep(Duration::from_millis(30)).await;
    assert_eq!(issuer.renewal_count(), 1);
}

#[tokio::test]
async fn remote_acme_renewal_loop_stops_while_check_is_in_flight() {
    let fixture = RenewalFixture::new((2026, 8, 1));
    let issuer = Arc::new(CancellableRenewalIssuer::new());
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let task = spawn_remote_acme_renewal_loop_with(
        Arc::clone(&fixture.db),
        fixture.tls.clone(),
        Arc::clone(&issuer),
        shutdown_rx,
        Duration::from_secs(60),
        || at("2026-07-10T00:00:00Z"),
    );

    timeout(Duration::from_secs(5), async {
        while !issuer.started() {
            sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("renewal check start timeout");
    shutdown_tx.send(true).expect("signal shutdown");

    timeout(Duration::from_secs(1), task)
        .await
        .expect("renewal loop did not stop while its check was in flight")
        .expect("renewal loop join");
    assert!(
        !issuer.active(),
        "renewal operation remained active after the loop stopped"
    );
}

struct RenewalFixture {
    db: Arc<Mutex<DaemonDb>>,
    tls: RemoteTlsConfigHandle,
    initial: RemoteCertificateBundle,
}

impl RenewalFixture {
    fn new(not_after: (i32, u8, u8)) -> Self {
        let db = DaemonDb::open_in_memory().expect("open daemon database");
        let initial = certificate_bundle(not_after);
        let account = RemoteAcmeAccountCredentials::new(
            "https://acme.test/acct/1",
            r#"{"id":"https://acme.test/acct/1","key_pkcs8":"account-secret"}"#,
        )
        .expect("ACME account");
        db.record_remote_acme_serve_config(&serve_config(), "2026-07-01T00:00:00Z")
            .expect("persist serve config");
        db.record_remote_acme_account(&account, "2026-07-01T00:00:00Z")
            .expect("persist ACME account");
        db.record_remote_acme_renewal_success(&initial, "2026-07-01T00:00:00Z")
            .expect("persist initial certificate");
        let tls = RemoteTlsConfigHandle::new(initial.clone()).expect("TLS config");
        Self {
            db: Arc::new(Mutex::new(db)),
            tls,
            initial,
        }
    }
}

struct FakeRenewalIssuer {
    renewals: AtomicUsize,
    reused_previous_certificate_identity: AtomicBool,
    result: Mutex<Result<RemoteCertificateBundle, String>>,
}

impl FakeRenewalIssuer {
    fn succeed(bundle: RemoteCertificateBundle) -> Self {
        Self {
            renewals: AtomicUsize::new(0),
            reused_previous_certificate_identity: AtomicBool::new(false),
            result: Mutex::new(Ok(bundle)),
        }
    }

    fn fail(detail: &str) -> Self {
        Self {
            renewals: AtomicUsize::new(0),
            reused_previous_certificate_identity: AtomicBool::new(false),
            result: Mutex::new(Err(detail.to_string())),
        }
    }

    fn renewal_count(&self) -> usize {
        self.renewals.load(Ordering::SeqCst)
    }

    fn reused_previous_certificate_identity(&self) -> bool {
        self.reused_previous_certificate_identity
            .load(Ordering::SeqCst)
    }
}

#[async_trait]
impl RemoteAcmeAutomaticRenewalIssuer for FakeRenewalIssuer {
    async fn renew_certificate_automatically(
        &self,
        request: &RemoteAcmeRenewalRequest,
        _cleanup_tracker: &RemoteAcmeCleanupTracker,
    ) -> Result<RemoteCertificateBundle, String> {
        self.renewals.fetch_add(1, Ordering::SeqCst);
        self.reused_previous_certificate_identity.store(
            request.previous_certificate_fingerprint().is_some()
                && request.previous_private_key_pem().is_some(),
            Ordering::SeqCst,
        );
        self.result.lock().expect("lock issuer result").clone()
    }
}

struct CancellableRenewalIssuer {
    started: AtomicBool,
    active: AtomicBool,
}

impl CancellableRenewalIssuer {
    const fn new() -> Self {
        Self {
            started: AtomicBool::new(false),
            active: AtomicBool::new(false),
        }
    }

    fn started(&self) -> bool {
        self.started.load(Ordering::SeqCst)
    }

    fn active(&self) -> bool {
        self.active.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl RemoteAcmeAutomaticRenewalIssuer for CancellableRenewalIssuer {
    async fn renew_certificate_automatically(
        &self,
        _request: &RemoteAcmeRenewalRequest,
        _cleanup_tracker: &RemoteAcmeCleanupTracker,
    ) -> Result<RemoteCertificateBundle, String> {
        self.started.store(true, Ordering::SeqCst);
        self.active.store(true, Ordering::SeqCst);
        let _activity = RenewalActivityGuard(&self.active);
        std::future::pending::<()>().await;
        unreachable!("cancellable renewal should remain pending")
    }
}

struct RenewalActivityGuard<'a>(&'a AtomicBool);

impl Drop for RenewalActivityGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

struct ConcurrentRenewalIssuer {
    db: Arc<Mutex<DaemonDb>>,
    manually_renewed: RemoteCertificateBundle,
    automatic_result: RemoteCertificateBundle,
}

#[async_trait]
impl RemoteAcmeAutomaticRenewalIssuer for ConcurrentRenewalIssuer {
    async fn renew_certificate_automatically(
        &self,
        _request: &RemoteAcmeRenewalRequest,
        _cleanup_tracker: &RemoteAcmeCleanupTracker,
    ) -> Result<RemoteCertificateBundle, String> {
        self.db
            .lock()
            .map_err(|error| error.to_string())?
            .record_remote_acme_renewal_success(&self.manually_renewed, "2026-07-10T00:00:00Z")
            .map_err(|error| error.to_string())?;
        Ok(self.automatic_result.clone())
    }
}

fn certificate_bundle(not_after: (i32, u8, u8)) -> RemoteCertificateBundle {
    let key = KeyPair::generate().expect("generate key");
    let mut params =
        CertificateParams::new(["daemon.example.com".to_string()]).expect("certificate params");
    params.not_before = date_time_ymd(2026, 1, 1);
    params.not_after = date_time_ymd(not_after.0, not_after.1, not_after.2);
    let certificate = params.self_signed(&key).expect("self-sign certificate");
    RemoteCertificateBundle::new(certificate.pem().as_str(), &key.serialize_pem())
}

fn serve_config() -> RemoteDaemonServeConfig {
    RemoteDaemonServeConfig {
        domain: "daemon.example.com".to_string(),
        host: "0.0.0.0".to_string(),
        https_port: 443,
        http_port: 80,
        acme_email: "ops@example.com".to_string(),
        acme_challenge: RemoteAcmeChallenge::TlsAlpn,
        acme_dns_provider: None,
    }
}

fn at(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .expect("RFC3339 timestamp")
        .with_timezone(&Utc)
}
