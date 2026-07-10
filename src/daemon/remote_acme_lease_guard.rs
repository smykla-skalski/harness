use std::future::Future;
use std::sync::Arc;

use super::remote_acme_cleanup::RemoteAcmeCleanupTracker;
use super::remote_acme_issuer::RemoteAcmeChallengeProvisioner;
use super::remote_redaction::redact_secret_detail;

pub(crate) struct RemoteAcmeChallengeLeaseGuard<P>
where
    P: RemoteAcmeChallengeProvisioner + 'static,
{
    provisioner: Arc<P>,
    cleanup_tracker: RemoteAcmeCleanupTracker,
    leases: Option<Vec<P::Lease>>,
}

impl<P> RemoteAcmeChallengeLeaseGuard<P>
where
    P: RemoteAcmeChallengeProvisioner + 'static,
{
    pub(crate) fn new(provisioner: Arc<P>, cleanup_tracker: RemoteAcmeCleanupTracker) -> Self {
        Self {
            provisioner,
            cleanup_tracker,
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

    pub(crate) async fn cleanup(mut self) -> Result<(), String> {
        let Some(cleanup) = self.take_cleanup() else {
            return Ok(());
        };
        self.cleanup_tracker
            .spawn_cleanup(cleanup)
            .await
            .map_err(|error| format!("join remote ACME challenge cleanup: {error}"))?
    }

    fn take_cleanup(
        &mut self,
    ) -> Option<impl Future<Output = Result<(), String>> + Send + 'static> {
        let leases = self.leases.take().filter(|leases| !leases.is_empty())?;
        Some(cleanup_leases(Arc::clone(&self.provisioner), leases))
    }
}

impl<P> Drop for RemoteAcmeChallengeLeaseGuard<P>
where
    P: RemoteAcmeChallengeProvisioner + 'static,
{
    fn drop(&mut self) {
        if let Some(cleanup) = self.take_cleanup() {
            drop(self.cleanup_tracker.spawn_cleanup(cleanup));
        }
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
