use std::io::{self, Write};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use tracing::instrument::WithSubscriber as _;
use tracing_subscriber::fmt::writer::MakeWriter;
use tracing_subscriber::layer::SubscriberExt as _;

use super::{
    FakeRenewalIssuer, RemoteAcmeRenewalCheckOutcome, RenewalFixture, at, certificate_bundle,
    run_remote_acme_renewal_check,
};
use crate::daemon::db::DaemonDb;
use crate::daemon::remote_acme::{
    RemoteAcmeAutomaticRenewalIssuer, RemoteAcmeRenewalRequest, RemoteCertificateBundle,
};
use crate::daemon::remote_acme_cleanup::RemoteAcmeCleanupTracker;
use crate::daemon::remote_tls::RemoteTlsConfigHandle;

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
async fn concurrent_active_manual_certificate_is_not_audited_as_automatic_reload() {
    let fixture = RenewalFixture::new((2026, 8, 1));
    let manually_renewed = certificate_bundle((2026, 12, 1));
    let issuer = ConcurrentActiveRenewalIssuer {
        db: Arc::clone(&fixture.db),
        tls: fixture.tls.clone(),
        manually_renewed: manually_renewed.clone(),
        automatic_result: certificate_bundle((2027, 1, 1)),
    };

    let outcome = run_remote_acme_renewal_check(
        &fixture.db,
        &fixture.tls,
        &issuer,
        at("2026-07-10T00:00:00Z"),
    )
    .await
    .expect("renewal check");

    assert_eq!(outcome, RemoteAcmeRenewalCheckOutcome::Superseded);
    assert_eq!(fixture.tls.generation(), 2);
    assert_eq!(
        fixture.tls.certificate_fingerprint(),
        manually_renewed.fingerprint()
    );
    let audits = fixture
        .db
        .lock()
        .expect("lock database")
        .load_remote_audit_events(10)
        .expect("load audit events");
    assert!(
        audits
            .iter()
            .any(|audit| audit.route_or_method == "remote.acme.renew.automatic.superseded")
    );
    assert!(
        audits
            .iter()
            .all(|audit| audit.route_or_method != "remote.tls.reload.automatic")
    );
}

#[tokio::test]
async fn persisted_tls_reload_failure_logs_early_renewal_fallback() {
    let fixture = RenewalFixture::new((2026, 9, 1));
    let persisted_certificate = certificate_bundle((2026, 12, 1));
    let wrong_key = certificate_bundle((2027, 1, 1));
    let mismatched = RemoteCertificateBundle::new_for_tests(
        persisted_certificate.certificate_pem(),
        wrong_key.private_key_pem(),
    );
    fixture
        .db
        .lock()
        .expect("lock database")
        .record_remote_acme_renewal_success(&mismatched, "2026-07-10T00:00:00Z")
        .expect("persist mismatched TLS material");
    let issuer = FakeRenewalIssuer::succeed(certificate_bundle((2027, 1, 1)));
    let output = SharedOutput::default();
    let subscriber = tracing_subscriber::registry().with(
        tracing_subscriber::fmt::layer()
            .with_ansi(false)
            .with_target(false)
            .with_writer(output.clone()),
    );

    let outcome = run_remote_acme_renewal_check(
        &fixture.db,
        &fixture.tls,
        &issuer,
        at("2026-07-10T00:00:00Z"),
    )
    .with_subscriber(subscriber)
    .await
    .expect("renewal check");

    assert_eq!(outcome, RemoteAcmeRenewalCheckOutcome::Renewed);
    assert_eq!(issuer.renewal_count(), 1);
    assert!(output.contents().contains(
        "persisted remote TLS certificate reload failed; attempting early ACME renewal"
    ));
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
        persist_manual_renewal(&self.db, &self.manually_renewed)?;
        Ok(self.automatic_result.clone())
    }
}

struct ConcurrentActiveRenewalIssuer {
    db: Arc<Mutex<DaemonDb>>,
    tls: RemoteTlsConfigHandle,
    manually_renewed: RemoteCertificateBundle,
    automatic_result: RemoteCertificateBundle,
}

#[async_trait]
impl RemoteAcmeAutomaticRenewalIssuer for ConcurrentActiveRenewalIssuer {
    async fn renew_certificate_automatically(
        &self,
        _request: &RemoteAcmeRenewalRequest,
        _cleanup_tracker: &RemoteAcmeCleanupTracker,
    ) -> Result<RemoteCertificateBundle, String> {
        persist_manual_renewal(&self.db, &self.manually_renewed)?;
        let reloaded = self
            .tls
            .reload(self.manually_renewed.clone())
            .map_err(|error| error.to_string())?;
        if !reloaded {
            return Err("manual renewal did not update live TLS".to_string());
        }
        Ok(self.automatic_result.clone())
    }
}

fn persist_manual_renewal(
    db: &Arc<Mutex<DaemonDb>>,
    bundle: &RemoteCertificateBundle,
) -> Result<(), String> {
    db.lock()
        .map_err(|error| error.to_string())?
        .record_remote_acme_renewal_success(bundle, "2026-07-10T00:00:00Z")
        .map_err(|error| error.to_string())
}

#[derive(Clone, Default)]
struct SharedOutput(Arc<Mutex<Vec<u8>>>);

impl SharedOutput {
    fn contents(&self) -> String {
        String::from_utf8(self.0.lock().expect("output lock").clone()).expect("UTF-8 logs")
    }
}

impl<'a> MakeWriter<'a> for SharedOutput {
    type Writer = SharedOutputWriter;

    fn make_writer(&'a self) -> Self::Writer {
        SharedOutputWriter(Arc::clone(&self.0))
    }
}

struct SharedOutputWriter(Arc<Mutex<Vec<u8>>>);

impl Write for SharedOutputWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.0
            .lock()
            .expect("output lock")
            .extend_from_slice(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
