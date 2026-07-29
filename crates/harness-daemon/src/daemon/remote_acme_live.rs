use std::fmt;

use async_trait::async_trait;

use super::remote::RemoteDaemonServeConfig;
use super::remote_acme::{
    RemoteAcmeAccountCredentials, RemoteAcmeAutomaticRenewalIssuer, RemoteAcmeRenewalIssuer,
    RemoteAcmeRenewalRequest, RemoteCertificateBundle,
};
use super::remote_acme_challenge::{
    SystemRemoteAcmeChallengeLease, SystemRemoteAcmeChallengeProvisioner,
};
use super::remote_acme_cleanup::RemoteAcmeCleanupTracker;
use super::remote_acme_issuer::{
    InstantAcmeIssuer, RemoteAcmeChallengeMaterial, RemoteAcmeChallengeProvisioner,
    SystemRemoteAcmeIssuer, run_acme_future,
};
use super::remote_tls::{RemoteTlsAlpnChallengeLease, RemoteTlsConfigHandle};

pub(crate) struct LiveRemoteAcmeChallengeProvisioner {
    system: SystemRemoteAcmeChallengeProvisioner,
    tls: RemoteTlsConfigHandle,
    domain: String,
    bind_host: String,
    https_port: u16,
}

impl LiveRemoteAcmeChallengeProvisioner {
    pub(crate) fn from_environment(
        config: &RemoteDaemonServeConfig,
        tls: RemoteTlsConfigHandle,
    ) -> Result<Self, String> {
        Ok(Self {
            system: SystemRemoteAcmeChallengeProvisioner::from_environment(config)?,
            tls,
            domain: config.domain.trim().to_string(),
            bind_host: config.host.trim().to_string(),
            https_port: config.https_port,
        })
    }

    fn validate_tls_listener(
        &self,
        domain: &str,
        bind_host: &str,
        port: u16,
    ) -> Result<(), String> {
        let matches = self.domain.eq_ignore_ascii_case(domain.trim())
            && self.bind_host == bind_host.trim()
            && self.https_port == port;
        if matches {
            Ok(())
        } else {
            Err("remote ACME TLS-ALPN-01 material does not match the active listener".to_string())
        }
    }
}

pub(crate) enum LiveRemoteAcmeChallengeLease {
    System(SystemRemoteAcmeChallengeLease),
    TlsAlpn(RemoteTlsAlpnChallengeLease),
}

impl fmt::Debug for LiveRemoteAcmeChallengeLease {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::System(_) => f.write_str("System(<redacted>)"),
            Self::TlsAlpn(lease) => f.debug_tuple("TlsAlpn").field(lease).finish(),
        }
    }
}

#[async_trait]
impl RemoteAcmeChallengeProvisioner for LiveRemoteAcmeChallengeProvisioner {
    type Lease = LiveRemoteAcmeChallengeLease;

    async fn present(&self, material: RemoteAcmeChallengeMaterial) -> Result<Self::Lease, String> {
        match material {
            RemoteAcmeChallengeMaterial::TlsAlpn01 {
                domain,
                bind_host,
                port,
                digest,
            } => {
                self.validate_tls_listener(&domain, &bind_host, port)?;
                self.tls
                    .present_tls_alpn_challenge(&domain, &digest)
                    .map(LiveRemoteAcmeChallengeLease::TlsAlpn)
                    .map_err(|error| error.to_string())
            }
            material => self
                .system
                .present(material)
                .await
                .map(LiveRemoteAcmeChallengeLease::System),
        }
    }

    async fn cleanup(&self, lease: Self::Lease) -> Result<(), String> {
        match lease {
            LiveRemoteAcmeChallengeLease::System(lease) => self.system.cleanup(lease).await,
            LiveRemoteAcmeChallengeLease::TlsAlpn(lease) => self
                .tls
                .clear_tls_alpn_challenge(lease)
                .map_err(|error| error.to_string()),
        }
    }

    async fn wait_ready(&self, lease: &Self::Lease) -> Result<(), String> {
        match lease {
            LiveRemoteAcmeChallengeLease::System(lease) => self.system.wait_ready(lease).await,
            LiveRemoteAcmeChallengeLease::TlsAlpn(_) => Ok(()),
        }
    }
}

#[derive(Clone)]
pub(crate) struct LiveRemoteAcmeIssuer {
    tls: RemoteTlsConfigHandle,
}

impl LiveRemoteAcmeIssuer {
    pub(crate) const fn new(tls: RemoteTlsConfigHandle) -> Self {
        Self { tls }
    }

    async fn issue_certificate(
        &self,
        request: &RemoteAcmeRenewalRequest,
        cleanup_tracker: RemoteAcmeCleanupTracker,
    ) -> Result<RemoteCertificateBundle, String> {
        let provisioner = LiveRemoteAcmeChallengeProvisioner::from_environment(
            request.serve_config(),
            self.tls.clone(),
        )?;
        InstantAcmeIssuer::production(provisioner)
            .issue_certificate_with_cleanup(
                request.account(),
                request.serve_config(),
                request.previous_private_key_pem(),
                cleanup_tracker,
            )
            .await
    }

    async fn issue_certificate_and_await_cleanup(
        &self,
        request: &RemoteAcmeRenewalRequest,
    ) -> Result<RemoteCertificateBundle, String> {
        let provisioner = LiveRemoteAcmeChallengeProvisioner::from_environment(
            request.serve_config(),
            self.tls.clone(),
        )?;
        InstantAcmeIssuer::production(provisioner)
            .issue_certificate_and_await_cleanup(
                request.account(),
                request.serve_config(),
                request.previous_private_key_pem(),
            )
            .await
    }
}

impl RemoteAcmeRenewalIssuer for LiveRemoteAcmeIssuer {
    fn create_account(
        &self,
        config: &RemoteDaemonServeConfig,
    ) -> Result<RemoteAcmeAccountCredentials, String> {
        SystemRemoteAcmeIssuer.create_account(config)
    }

    fn renew_certificate(
        &self,
        request: &RemoteAcmeRenewalRequest,
    ) -> Result<RemoteCertificateBundle, String> {
        run_acme_future(self.issue_certificate_and_await_cleanup(request))
    }
}

#[async_trait]
impl RemoteAcmeAutomaticRenewalIssuer for LiveRemoteAcmeIssuer {
    async fn renew_certificate_automatically(
        &self,
        request: &RemoteAcmeRenewalRequest,
        cleanup_tracker: &RemoteAcmeCleanupTracker,
    ) -> Result<RemoteCertificateBundle, String> {
        self.issue_certificate(request, cleanup_tracker.clone())
            .await
    }
}

#[cfg(test)]
#[path = "remote_acme_live_tests.rs"]
mod tests;
