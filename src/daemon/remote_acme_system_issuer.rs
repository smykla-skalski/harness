use std::future::Future;
use std::thread;

use tokio::runtime::{Handle, Runtime};

use crate::daemon::remote::RemoteDaemonServeConfig;
use crate::daemon::remote_acme::{
    RemoteAcmeAccountCredentials, RemoteAcmeRenewalIssuer, RemoteAcmeRenewalRequest,
    RemoteCertificateBundle,
};
use crate::daemon::remote_acme_challenge::SystemRemoteAcmeChallengeProvisioner;
use crate::daemon::remote_acme_cleanup::RemoteAcmeCleanupTracker;

use super::InstantAcmeIssuer;

pub(crate) struct SystemRemoteAcmeIssuer;

impl SystemRemoteAcmeIssuer {
    pub(crate) async fn create_account_async(
        &self,
        config: &RemoteDaemonServeConfig,
    ) -> Result<RemoteAcmeAccountCredentials, String> {
        let provisioner = SystemRemoteAcmeChallengeProvisioner::from_environment(config)?;
        InstantAcmeIssuer::production(provisioner)
            .create_account(config.acme_email.as_str())
            .await
    }

    pub(crate) async fn renew_certificate_async(
        &self,
        request: &RemoteAcmeRenewalRequest,
        cleanup_tracker: RemoteAcmeCleanupTracker,
    ) -> Result<RemoteCertificateBundle, String> {
        let provisioner =
            SystemRemoteAcmeChallengeProvisioner::from_environment(request.serve_config())?;
        InstantAcmeIssuer::production(provisioner)
            .issue_certificate_with_cleanup(
                request.account(),
                request.serve_config(),
                request.previous_private_key_pem(),
                cleanup_tracker,
            )
            .await
    }

    async fn renew_certificate_and_await_cleanup_async(
        &self,
        request: &RemoteAcmeRenewalRequest,
    ) -> Result<RemoteCertificateBundle, String> {
        let provisioner =
            SystemRemoteAcmeChallengeProvisioner::from_environment(request.serve_config())?;
        InstantAcmeIssuer::production(provisioner)
            .issue_certificate_and_await_cleanup(
                request.account(),
                request.serve_config(),
                request.previous_private_key_pem(),
            )
            .await
    }
}

impl RemoteAcmeRenewalIssuer for SystemRemoteAcmeIssuer {
    fn create_account(
        &self,
        config: &RemoteDaemonServeConfig,
    ) -> Result<RemoteAcmeAccountCredentials, String> {
        run_acme_future(self.create_account_async(config))
    }

    fn renew_certificate(
        &self,
        request: &RemoteAcmeRenewalRequest,
    ) -> Result<RemoteCertificateBundle, String> {
        run_acme_future(self.renew_certificate_and_await_cleanup_async(request))
    }
}

pub(crate) fn run_acme_future<T, F>(future: F) -> Result<T, String>
where
    T: Send,
    F: Future<Output = Result<T, String>> + Send,
{
    if Handle::try_current().is_ok() {
        return thread::scope(|scope| {
            scope
                .spawn(move || run_acme_future_on_runtime(future))
                .join()
                .map_err(|_| "remote ACME runtime thread panicked".to_string())?
        });
    }
    run_acme_future_on_runtime(future)
}

fn run_acme_future_on_runtime<T, F>(future: F) -> Result<T, String>
where
    F: Future<Output = Result<T, String>>,
{
    Runtime::new()
        .map_err(|error| format!("create remote ACME runtime: {error}"))?
        .block_on(future)
}
