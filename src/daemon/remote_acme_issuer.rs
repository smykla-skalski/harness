use std::env;
use std::fmt;
use std::future::Future;
use std::path::PathBuf;
use std::sync::Arc;
use std::thread;

use async_trait::async_trait;
use instant_acme::{
    Account, AccountBuilder, AccountCredentials, AuthorizationStatus, ChallengeHandle,
    ChallengeType, Identifier, LetsEncrypt, NewAccount, NewOrder, Order, OrderStatus, RetryPolicy,
};
use rcgen::{CertificateParams, DistinguishedName, KeyPair};
use tokio::runtime::{Handle, Runtime};

use super::remote::{
    RemoteAcmeChallenge, RemoteDaemonServeConfig, RemoteDnsProvider, validate_remote_serve_config,
};
use super::remote_acme::{
    RemoteAcmeAccountCredentials, RemoteAcmeRenewalIssuer, RemoteAcmeRenewalRequest,
    RemoteCertificateBundle,
};
use super::remote_acme_challenge::SystemRemoteAcmeChallengeProvisioner;
use super::remote_redaction::redact_secret_detail;

type AccountBuilderFactory = dyn Fn() -> Result<AccountBuilder, String> + Send + Sync + 'static;

#[derive(Clone, PartialEq, Eq)]
pub(crate) enum RemoteAcmeChallengeMaterial {
    Http01 {
        domain: String,
        bind_host: String,
        port: u16,
        token: String,
        key_authorization: String,
    },
    Dns01 {
        domain: String,
        provider: RemoteDnsProvider,
        record_name: String,
        record_value: String,
    },
    TlsAlpn01 {
        domain: String,
        bind_host: String,
        port: u16,
        digest: Vec<u8>,
    },
}

impl fmt::Debug for RemoteAcmeChallengeMaterial {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Http01 {
                domain,
                bind_host,
                port,
                token,
                ..
            } => f
                .debug_struct("Http01")
                .field("domain", domain)
                .field("bind_host", bind_host)
                .field("port", port)
                .field("token", token)
                .field("key_authorization", &"<redacted>")
                .finish(),
            Self::Dns01 {
                domain,
                provider,
                record_name,
                ..
            } => f
                .debug_struct("Dns01")
                .field("domain", domain)
                .field("provider", provider)
                .field("record_name", record_name)
                .field("record_value", &"<redacted>")
                .finish(),
            Self::TlsAlpn01 {
                domain,
                bind_host,
                port,
                ..
            } => f
                .debug_struct("TlsAlpn01")
                .field("domain", domain)
                .field("bind_host", bind_host)
                .field("port", port)
                .field("digest", &"<redacted>")
                .finish(),
        }
    }
}

#[async_trait]
pub(crate) trait RemoteAcmeChallengeProvisioner: Send + Sync {
    type Lease: Send;

    async fn present(&self, material: RemoteAcmeChallengeMaterial) -> Result<Self::Lease, String>;

    async fn cleanup(&self, lease: Self::Lease) -> Result<(), String>;
}

pub(crate) struct InstantAcmeIssuer<P> {
    provisioner: P,
    directory_url: String,
    retry_policy: RetryPolicy,
    account_builder: Arc<AccountBuilderFactory>,
}

impl<P> InstantAcmeIssuer<P>
where
    P: RemoteAcmeChallengeProvisioner,
{
    pub(crate) fn with_account_builder<F>(
        provisioner: P,
        directory_url: &str,
        retry_policy: RetryPolicy,
        account_builder: F,
    ) -> Self
    where
        F: Fn() -> Result<AccountBuilder, String> + Send + Sync + 'static,
    {
        Self {
            provisioner,
            directory_url: directory_url.trim().to_string(),
            retry_policy,
            account_builder: Arc::new(account_builder),
        }
    }

    pub(crate) fn production(provisioner: P) -> Self {
        let directory_url = env::var("HARNESS_REMOTE_ACME_DIRECTORY_URL")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| LetsEncrypt::Production.url().to_string());
        let root_path = env::var("HARNESS_REMOTE_ACME_CA_ROOT")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .map(PathBuf::from);
        Self::with_account_builder(
            provisioner,
            &directory_url,
            RetryPolicy::default(),
            move || match &root_path {
                Some(path) => {
                    Account::builder_with_root(path).map_err(|error| redacted_acme_error(&error))
                }
                None => Account::builder().map_err(|error| redacted_acme_error(&error)),
            },
        )
    }

    pub(crate) async fn create_account(
        &self,
        email: &str,
    ) -> Result<RemoteAcmeAccountCredentials, String> {
        let email = email.trim();
        if email.is_empty() {
            return Err("remote ACME account email is required".to_string());
        }
        if self.directory_url.is_empty() {
            return Err("remote ACME directory URL is required".to_string());
        }
        let contact = format!("mailto:{email}");
        let contacts = [contact.as_str()];
        let builder = (self.account_builder)()?;
        let (_, credentials) = builder
            .create(
                &NewAccount {
                    contact: &contacts,
                    terms_of_service_agreed: true,
                    only_return_existing: false,
                },
                self.directory_url.clone(),
                None,
            )
            .await
            .map_err(|error| redacted_acme_error(&error))?;
        project_account_credentials(&credentials)
    }

    pub(crate) async fn issue_certificate(
        &self,
        credentials: &RemoteAcmeAccountCredentials,
        config: &RemoteDaemonServeConfig,
        previous_private_key_pem: Option<&str>,
    ) -> Result<RemoteCertificateBundle, String> {
        validate_remote_serve_config(config).map_err(|error| error.to_string())?;
        let account = self.restore_account(credentials).await?;
        let identifiers = [Identifier::Dns(config.domain.trim().to_string())];
        let mut order = account
            .new_order(&NewOrder::new(&identifiers))
            .await
            .map_err(|error| redacted_acme_error(&error))?;
        self.complete_authorizations(&mut order, config).await?;
        let private_key = previous_private_key_pem.map_or_else(
            || KeyPair::generate().map_err(|error| error.to_string()),
            |pem| KeyPair::from_pem(pem).map_err(|error| error.to_string()),
        )?;
        let private_key_pem = private_key.serialize_pem();
        let mut params = CertificateParams::new(vec![config.domain.trim().to_string()])
            .map_err(|error| error.to_string())?;
        params.distinguished_name = DistinguishedName::new();
        let csr = params
            .serialize_request(&private_key)
            .map_err(|error| error.to_string())?;
        order
            .finalize_csr(csr.der())
            .await
            .map_err(|error| redacted_acme_error(&error))?;
        let certificate = order
            .poll_certificate(&self.retry_policy)
            .await
            .map_err(|error| redacted_acme_error(&error))?;
        Ok(RemoteCertificateBundle::new(&certificate, &private_key_pem))
    }

    async fn restore_account(
        &self,
        credentials: &RemoteAcmeAccountCredentials,
    ) -> Result<Account, String> {
        let credentials = serde_json::from_str::<AccountCredentials>(credentials.serialized())
            .map_err(|error| format!("deserialize remote ACME account credentials: {error}"))?;
        (self.account_builder)()?
            .from_credentials(credentials)
            .await
            .map_err(|error| redacted_acme_error(&error))
    }

    async fn complete_authorizations(
        &self,
        order: &mut Order,
        config: &RemoteDaemonServeConfig,
    ) -> Result<(), String> {
        let mut leases = Vec::new();
        let authorization_result = self
            .present_pending_authorizations(order, config, &mut leases)
            .await;
        if let Err(error) = authorization_result {
            return self.cleanup_after_error(leases, error).await;
        }
        let poll_result = order
            .poll_ready(&self.retry_policy)
            .await
            .map_err(|error| redacted_acme_error(&error))
            .and_then(|status| {
                if status == OrderStatus::Ready {
                    Ok(())
                } else {
                    Err(format!("remote ACME order became {status:?}"))
                }
            });
        match (poll_result, self.cleanup_all(leases).await) {
            (Ok(()), Ok(())) => Ok(()),
            (Err(error), Ok(())) | (Ok(()), Err(error)) => Err(error),
            (Err(issue), Err(cleanup)) => Err(format!(
                "{issue}; remote ACME challenge cleanup also failed: {cleanup}"
            )),
        }
    }

    async fn present_pending_authorizations(
        &self,
        order: &mut Order,
        config: &RemoteDaemonServeConfig,
        leases: &mut Vec<P::Lease>,
    ) -> Result<(), String> {
        let mut authorizations = order.authorizations();
        while let Some(result) = authorizations.next().await {
            let mut authorization = result.map_err(|error| redacted_acme_error(&error))?;
            match authorization.status {
                AuthorizationStatus::Valid => continue,
                AuthorizationStatus::Pending => {}
                status => {
                    return Err(format!(
                        "remote ACME authorization is not pending: {status:?}"
                    ));
                }
            }
            let challenge_type = challenge_type(config.acme_challenge);
            let mut challenge = authorization.challenge(challenge_type).ok_or_else(|| {
                format!(
                    "remote ACME server did not offer {} challenge",
                    config.acme_challenge.as_str()
                )
            })?;
            let material = challenge_material(&challenge, config)?;
            let lease = self.provisioner.present(material).await?;
            if let Err(error) = challenge
                .set_ready()
                .await
                .map_err(|error| redacted_acme_error(&error))
            {
                return self.cleanup_after_error(vec![lease], error).await;
            }
            leases.push(lease);
        }
        Ok(())
    }

    async fn cleanup_all(&self, leases: Vec<P::Lease>) -> Result<(), String> {
        let mut failures = Vec::new();
        for lease in leases {
            if let Err(error) = self.provisioner.cleanup(lease).await {
                failures.push(redact_secret_detail(&error));
            }
        }
        if failures.is_empty() {
            Ok(())
        } else {
            Err(failures.join("; "))
        }
    }

    async fn cleanup_after_error(
        &self,
        leases: Vec<P::Lease>,
        issue: String,
    ) -> Result<(), String> {
        match self.cleanup_all(leases).await {
            Ok(()) => Err(issue),
            Err(cleanup) => Err(format!(
                "{issue}; remote ACME challenge cleanup also failed: {cleanup}"
            )),
        }
    }
}

fn project_account_credentials(
    credentials: &AccountCredentials,
) -> Result<RemoteAcmeAccountCredentials, String> {
    let serialized = serde_json::to_string(credentials)
        .map_err(|error| format!("serialize remote ACME account credentials: {error}"))?;
    let value = serde_json::from_str::<serde_json::Value>(&serialized)
        .map_err(|error| format!("inspect remote ACME account credentials: {error}"))?;
    let account_id = value
        .get("id")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "remote ACME account credentials omit account id".to_string())?;
    RemoteAcmeAccountCredentials::new(account_id, &serialized).map_err(|error| error.to_string())
}

fn challenge_type(challenge: RemoteAcmeChallenge) -> ChallengeType {
    match challenge {
        RemoteAcmeChallenge::TlsAlpn => ChallengeType::TlsAlpn01,
        RemoteAcmeChallenge::Http => ChallengeType::Http01,
        RemoteAcmeChallenge::Dns => ChallengeType::Dns01,
    }
}

fn challenge_material(
    challenge: &ChallengeHandle<'_>,
    config: &RemoteDaemonServeConfig,
) -> Result<RemoteAcmeChallengeMaterial, String> {
    let domain = challenge.identifier().to_string();
    if domain != config.domain.trim() {
        return Err(format!(
            "remote ACME authorization domain mismatch: expected {}, received {domain}",
            config.domain.trim()
        ));
    }
    let key_authorization = challenge.key_authorization();
    match config.acme_challenge {
        RemoteAcmeChallenge::Http => Ok(RemoteAcmeChallengeMaterial::Http01 {
            domain,
            bind_host: config.host.trim().to_string(),
            port: config.http_port,
            token: challenge.token.clone(),
            key_authorization: key_authorization.as_str().to_string(),
        }),
        RemoteAcmeChallenge::Dns => Ok(RemoteAcmeChallengeMaterial::Dns01 {
            record_name: format!("_acme-challenge.{domain}"),
            domain,
            provider: config
                .acme_dns_provider
                .ok_or_else(|| "remote ACME DNS provider is required".to_string())?,
            record_value: key_authorization.dns_value(),
        }),
        RemoteAcmeChallenge::TlsAlpn => Ok(RemoteAcmeChallengeMaterial::TlsAlpn01 {
            domain,
            bind_host: config.host.trim().to_string(),
            port: config.https_port,
            digest: key_authorization.digest().as_ref().to_vec(),
        }),
    }
}

fn redacted_acme_error(error: &instant_acme::Error) -> String {
    redact_secret_detail(&error.to_string())
}

pub(crate) struct SystemRemoteAcmeIssuer;

impl RemoteAcmeRenewalIssuer for SystemRemoteAcmeIssuer {
    fn create_account(
        &self,
        config: &RemoteDaemonServeConfig,
    ) -> Result<RemoteAcmeAccountCredentials, String> {
        let provisioner = SystemRemoteAcmeChallengeProvisioner::from_environment(config)?;
        let issuer = InstantAcmeIssuer::production(provisioner);
        run_acme_future(issuer.create_account(config.acme_email.as_str()))
    }

    fn renew_certificate(
        &self,
        request: &RemoteAcmeRenewalRequest,
    ) -> Result<RemoteCertificateBundle, String> {
        let provisioner =
            SystemRemoteAcmeChallengeProvisioner::from_environment(request.serve_config())?;
        let issuer = InstantAcmeIssuer::production(provisioner);
        run_acme_future(issuer.issue_certificate(
            request.account(),
            request.serve_config(),
            request.previous_private_key_pem(),
        ))
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

#[cfg(test)]
#[path = "remote_acme_issuer_tests.rs"]
mod tests;
