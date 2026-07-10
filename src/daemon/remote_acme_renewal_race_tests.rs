use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use super::{
    RemoteAcmeRenewalCheckOutcome, RenewalFixture, at, certificate_bundle,
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
