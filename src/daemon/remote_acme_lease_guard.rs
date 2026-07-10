use std::sync::Arc;

use super::remote_acme_issuer::{RemoteAcmeChallengeProvisioner, run_acme_future};
use super::remote_redaction::redact_secret_detail;

pub(crate) struct RemoteAcmeChallengeLeaseGuard<P>
where
    P: RemoteAcmeChallengeProvisioner + 'static,
{
    provisioner: Arc<P>,
    leases: Option<Vec<P::Lease>>,
}

impl<P> RemoteAcmeChallengeLeaseGuard<P>
where
    P: RemoteAcmeChallengeProvisioner + 'static,
{
    pub(crate) fn new(provisioner: Arc<P>) -> Self {
        Self {
            provisioner,
            leases: Some(Vec::new()),
        }
    }

    pub(crate) fn push(&mut self, lease: P::Lease) {
        self.leases
            .as_mut()
            .expect("active ACME lease guard")
            .push(lease);
    }

    pub(crate) fn last(&self) -> Option<&P::Lease> {
        self.leases.as_ref().and_then(|leases| leases.last())
    }

    pub(crate) fn cleanup(mut self) -> Result<(), String> {
        self.cleanup_remaining()
    }

    fn cleanup_remaining(&mut self) -> Result<(), String> {
        let Some(leases) = self.leases.take() else {
            return Ok(());
        };
        if leases.is_empty() {
            return Ok(());
        }
        let provisioner = Arc::clone(&self.provisioner);
        run_acme_future(cleanup_leases(provisioner, leases))
    }
}

impl<P> Drop for RemoteAcmeChallengeLeaseGuard<P>
where
    P: RemoteAcmeChallengeProvisioner + 'static,
{
    fn drop(&mut self) {
        let result = self.cleanup_remaining();
        log_cancellation_cleanup(&result);
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_cancellation_cleanup(result: &Result<(), String>) {
    if let Err(error) = result {
        tracing::warn!(
            error = %redact_secret_detail(error),
            "remote ACME challenge cleanup after cancellation failed",
        );
    }
}

async fn cleanup_leases<P>(provisioner: Arc<P>, leases: Vec<P::Lease>) -> Result<(), String>
where
    P: RemoteAcmeChallengeProvisioner + 'static,
{
    let mut failures = Vec::new();
    for lease in leases {
        if let Err(error) = provisioner.cleanup(lease).await {
            failures.push(redact_secret_detail(&error));
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("; "))
    }
}
