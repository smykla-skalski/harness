use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;

use sha2::{Digest, Sha256};

use super::protocol::http_paths;
use super::remote::{
    RemoteAcmeChallenge, RemoteDaemonConfigError, RemoteDaemonServeConfig,
    validate_remote_serve_config,
};
use super::remote_certificate_identity::RemotePrivateKeyPem;
pub use super::remote_acme_dns::{
    CloudflareDns01ChangeRequest, Dns01ChangeOperation, Dns01ExecHookError,
    Dns01ExecHookInvocation, Dns01ExecHookOperation, Dns01ProviderChangeError,
    Route53Dns01ChangeBatch,
};
pub use super::remote_acme_dns_runner::{
    Dns01ProviderAction, Dns01ProviderChangeRunner, Dns01ProviderExecutionConfig,
    Dns01ProviderExecutionError,
};
use super::remote_redaction::redact_secret_detail;

#[cfg(test)]
#[path = "remote_acme_dns_runner_tests.rs"]
mod dns_runner_tests;
#[cfg(test)]
#[path = "remote_acme_tests.rs"]
mod tests;

const HTTPS_ALPN_PROTOCOLS: &[&[u8]] = &[b"h2", b"http/1.1"];
const TLS_ALPN_CHALLENGE_PROTOCOLS: &[&[u8]] = &[b"acme-tls/1"];
const NO_CHALLENGE_ALPN_PROTOCOLS: &[&[u8]] = &[];
const HTTP01_PREFIX: &str = "/.well-known/acme-challenge/";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteAcmeRuntimeError {
    InvalidConfig(RemoteDaemonConfigError),
    MissingPersistedAcmeState,
    MissingCertificate,
}

impl fmt::Display for RemoteAcmeRuntimeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidConfig(error) => write!(f, "{error}"),
            Self::MissingPersistedAcmeState => {
                write!(f, "remote daemon requires persisted ACME state")
            }
            Self::MissingCertificate => {
                write!(f, "remote daemon requires a persisted TLS certificate")
            }
        }
    }
}

impl Error for RemoteAcmeRuntimeError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::InvalidConfig(error) => Some(error),
            Self::MissingPersistedAcmeState | Self::MissingCertificate => None,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RemoteAcmeRuntimeState {
    acme_account_id: Option<String>,
    certificate: Option<RemoteCertificateBundle>,
}

impl RemoteAcmeRuntimeState {
    #[must_use]
    pub fn with_account(account_id: impl Into<String>) -> Self {
        Self {
            acme_account_id: Some(account_id.into()),
            certificate: None,
        }
    }

    #[must_use]
    pub fn with_account_and_certificate(
        account_id: impl Into<String>,
        certificate: RemoteCertificateBundle,
    ) -> Self {
        Self {
            acme_account_id: Some(account_id.into()),
            certificate: Some(certificate),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteAcmeRuntimePlan {
    domain: String,
    https_port: u16,
    challenge: RemoteAcmeChallenge,
    certificate: RemoteCertificateBundle,
}

impl RemoteAcmeRuntimePlan {
    #[must_use]
    pub fn public_https_origin(&self) -> String {
        if self.https_port == 443 {
            format!("https://{}", self.domain)
        } else {
            format!("https://{}:{}", self.domain, self.https_port)
        }
    }

    #[must_use]
    pub fn public_wss_url(&self) -> String {
        let host = if self.https_port == 443 {
            self.domain.clone()
        } else {
            format!("{}:{}", self.domain, self.https_port)
        };
        format!("wss://{host}{}", http_paths::WS)
    }

    #[must_use]
    pub const fn uses_rustls_https(&self) -> bool {
        true
    }

    #[must_use]
    pub const fn https_alpn_protocols(&self) -> &'static [&'static [u8]] {
        HTTPS_ALPN_PROTOCOLS
    }

    #[must_use]
    pub const fn challenge_alpn_protocols(&self) -> &'static [&'static [u8]] {
        match self.challenge {
            RemoteAcmeChallenge::TlsAlpn => TLS_ALPN_CHALLENGE_PROTOCOLS,
            RemoteAcmeChallenge::Http | RemoteAcmeChallenge::Dns => NO_CHALLENGE_ALPN_PROTOCOLS,
        }
    }

    #[must_use]
    pub const fn certificate(&self) -> &RemoteCertificateBundle {
        &self.certificate
    }
}

/// Build the remote daemon TLS/ACME runtime plan.
///
/// # Errors
/// Returns [`RemoteAcmeRuntimeError`] when the static config is invalid or
/// persisted ACME account/certificate state is missing.
pub fn build_remote_acme_runtime_plan(
    config: &RemoteDaemonServeConfig,
    state: &RemoteAcmeRuntimeState,
) -> Result<RemoteAcmeRuntimePlan, RemoteAcmeRuntimeError> {
    validate_remote_serve_config(config).map_err(RemoteAcmeRuntimeError::InvalidConfig)?;
    if state
        .acme_account_id
        .as_deref()
        .unwrap_or_default()
        .trim()
        .is_empty()
    {
        return Err(RemoteAcmeRuntimeError::MissingPersistedAcmeState);
    }
    let certificate = state
        .certificate
        .clone()
        .ok_or(RemoteAcmeRuntimeError::MissingCertificate)?;
    if !certificate.has_material() {
        return Err(RemoteAcmeRuntimeError::MissingCertificate);
    }

    Ok(RemoteAcmeRuntimePlan {
        domain: config.domain.trim().to_string(),
        https_port: config.https_port,
        challenge: config.acme_challenge,
        certificate,
    })
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AcmeHttp01ChallengeStore {
    authorizations: BTreeMap<String, String>,
}

impl AcmeHttp01ChallengeStore {
    #[must_use]
    pub fn from_pairs<const N: usize>(pairs: [(&str, &str); N]) -> Self {
        Self {
            authorizations: pairs
                .into_iter()
                .map(|(token, authorization)| (token.to_string(), authorization.to_string()))
                .collect(),
        }
    }

    #[must_use]
    pub fn response_for_path(&self, path: &str) -> Option<&str> {
        let token = path.strip_prefix(HTTP01_PREFIX)?;
        if token.is_empty() || token.contains('/') || token.contains("..") {
            return None;
        }
        self.authorizations.get(token).map(String::as_str)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteAcmeRenewalRequest {
    account: RemoteAcmeAccountCredentials,
    previous_certificate_fingerprint: Option<String>,
    previous_private_key_pem: Option<RemotePrivateKeyPem>,
    serve_config: RemoteDaemonServeConfig,
}

impl RemoteAcmeRenewalRequest {
    #[must_use]
    pub fn new(
        account: &RemoteAcmeAccountCredentials,
        previous_fingerprint: Option<&str>,
        previous_private_key_pem: Option<&str>,
        serve_config: &RemoteDaemonServeConfig,
    ) -> Self {
        Self {
            account: account.clone(),
            previous_certificate_fingerprint: previous_fingerprint.map(ToOwned::to_owned),
            previous_private_key_pem: previous_private_key_pem.map(RemotePrivateKeyPem::new),
            serve_config: serve_config.clone(),
        }
    }

    #[must_use]
    pub fn account_id(&self) -> &str {
        self.account.account_id()
    }

    #[must_use]
    pub fn account_credentials(&self) -> &str {
        self.account.serialized()
    }

    #[must_use]
    pub(crate) const fn account(&self) -> &RemoteAcmeAccountCredentials {
        &self.account
    }

    #[must_use]
    pub fn previous_certificate_fingerprint(&self) -> Option<&str> {
        self.previous_certificate_fingerprint.as_deref()
    }

    #[must_use]
    pub fn previous_private_key_pem(&self) -> Option<&str> {
        self.previous_private_key_pem.as_ref().map(RemotePrivateKeyPem::as_str)
    }

    #[must_use]
    pub const fn serve_config(&self) -> &RemoteDaemonServeConfig {
        &self.serve_config
    }
}

pub trait RemoteAcmeRenewalIssuer {
    /// Create a durable ACME account for the configured certificate authority.
    ///
    /// # Errors
    /// Returns a redaction-ready operator detail when account creation fails.
    fn create_account(
        &self,
        config: &RemoteDaemonServeConfig,
    ) -> Result<RemoteAcmeAccountCredentials, String>;

    /// Issue or renew the remote daemon certificate for the supplied account.
    ///
    /// # Errors
    /// Returns a redaction-ready operator detail when the issuer cannot produce
    /// a certificate bundle.
    fn renew_certificate(
        &self,
        request: &RemoteAcmeRenewalRequest,
    ) -> Result<RemoteCertificateBundle, String>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteAcmeAccountCredentialsError {
    MissingAccountId,
    MissingSerializedCredentials,
    InvalidSerializedCredentials(String),
    AccountIdMismatch,
}

impl fmt::Display for RemoteAcmeAccountCredentialsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingAccountId => write!(f, "remote ACME account id is required"),
            Self::MissingSerializedCredentials => {
                write!(f, "remote ACME serialized account credentials are required")
            }
            Self::InvalidSerializedCredentials(error) => {
                write!(
                    f,
                    "remote ACME serialized account credentials are invalid: {error}"
                )
            }
            Self::AccountIdMismatch => {
                write!(
                    f,
                    "remote ACME account id does not match serialized credentials"
                )
            }
        }
    }
}

impl Error for RemoteAcmeAccountCredentialsError {}

#[derive(Clone, PartialEq, Eq)]
pub struct RemoteAcmeAccountCredentials {
    account_id: String,
    serialized: String,
}

impl fmt::Debug for RemoteAcmeAccountCredentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RemoteAcmeAccountCredentials")
            .field("account_id", &self.account_id)
            .field("serialized", &"<redacted>")
            .finish()
    }
}

impl RemoteAcmeAccountCredentials {
    /// Build validated serialized ACME account credentials.
    ///
    /// # Errors
    /// Returns [`RemoteAcmeAccountCredentialsError`] when either field is
    /// blank, the serialized value is not a JSON object, or its account id
    /// differs from the projected id.
    pub fn new(
        account_id: &str,
        serialized: &str,
    ) -> Result<Self, RemoteAcmeAccountCredentialsError> {
        let account_id = account_id.trim();
        if account_id.is_empty() {
            return Err(RemoteAcmeAccountCredentialsError::MissingAccountId);
        }
        let serialized = serialized.trim();
        if serialized.is_empty() {
            return Err(RemoteAcmeAccountCredentialsError::MissingSerializedCredentials);
        }
        let value = serde_json::from_str::<serde_json::Value>(serialized).map_err(|error| {
            RemoteAcmeAccountCredentialsError::InvalidSerializedCredentials(error.to_string())
        })?;
        let object = value.as_object().ok_or_else(|| {
            RemoteAcmeAccountCredentialsError::InvalidSerializedCredentials(
                "expected a JSON object".to_string(),
            )
        })?;
        if object.get("id").and_then(serde_json::Value::as_str) != Some(account_id) {
            return Err(RemoteAcmeAccountCredentialsError::AccountIdMismatch);
        }
        Ok(Self {
            account_id: account_id.to_string(),
            serialized: serialized.to_string(),
        })
    }

    #[must_use]
    pub fn account_id(&self) -> &str {
        &self.account_id
    }

    #[must_use]
    pub fn serialized(&self) -> &str {
        &self.serialized
    }
}

#[derive(Clone, Default, PartialEq, Eq)]
pub struct RemoteAcmeIssuanceState {
    pub(crate) account: Option<RemoteAcmeAccountCredentials>,
    pub(crate) previous_private_key_pem: Option<String>,
}

impl fmt::Debug for RemoteAcmeIssuanceState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RemoteAcmeIssuanceState")
            .field("account_configured", &self.account.is_some())
            .field(
                "private_key_configured",
                &self.previous_private_key_pem.is_some(),
            )
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct RemoteCertificateBundle {
    certificate_pem: String,
    private_key_pem: String,
    fingerprint: String,
}

impl fmt::Debug for RemoteCertificateBundle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RemoteCertificateBundle")
            .field("certificate_pem", &"<redacted>")
            .field("private_key_pem", &"<redacted>")
            .field("fingerprint", &self.fingerprint)
            .finish()
    }
}

impl RemoteCertificateBundle {
    #[cfg(test)]
    #[must_use]
    pub fn new_for_tests(certificate_pem: &str, private_key_pem: &str) -> Self {
        Self::new(certificate_pem, private_key_pem)
    }

    #[must_use]
    pub fn new(certificate_pem: &str, private_key_pem: &str) -> Self {
        let mut hasher = Sha256::new();
        hasher.update(certificate_pem.as_bytes());
        hasher.update(b"\0");
        hasher.update(private_key_pem.as_bytes());
        let fingerprint = hex::encode(hasher.finalize());
        Self {
            certificate_pem: certificate_pem.to_string(),
            private_key_pem: private_key_pem.to_string(),
            fingerprint,
        }
    }

    #[must_use]
    pub fn fingerprint(&self) -> &str {
        &self.fingerprint
    }

    #[must_use]
    pub(crate) fn certificate_pem(&self) -> &str {
        &self.certificate_pem
    }

    #[must_use]
    pub(crate) fn private_key_pem(&self) -> &str {
        &self.private_key_pem
    }

    pub(crate) fn spki_sha256_pin(
        &self,
    ) -> Result<String, super::remote_certificate_identity::RemoteCertificateIdentityError> {
        super::remote_certificate_identity::spki_sha256_pin(self)
    }

    #[must_use]
    pub fn has_material(&self) -> bool {
        !self.certificate_pem.trim().is_empty() && !self.private_key_pem.trim().is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteCertificateSlot {
    bundle: RemoteCertificateBundle,
    generation: u64,
}

impl RemoteCertificateSlot {
    #[must_use]
    pub const fn new(bundle: RemoteCertificateBundle) -> Self {
        Self {
            bundle,
            generation: 1,
        }
    }

    #[must_use]
    pub const fn generation(&self) -> u64 {
        self.generation
    }

    pub fn reload(&mut self, bundle: RemoteCertificateBundle) -> bool {
        if self.bundle.fingerprint() == bundle.fingerprint() {
            return false;
        }
        self.bundle = bundle;
        self.generation += 1;
        true
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteRenewalOutcome {
    Succeeded,
    Failed { report: String },
}

impl RemoteRenewalOutcome {
    #[must_use]
    pub fn failure(detail: &str) -> Self {
        Self::Failed {
            report: format!("renewal failed: {}", redact_secret_detail(detail)),
        }
    }

    #[must_use]
    pub const fn is_failure(&self) -> bool {
        matches!(self, Self::Failed { .. })
    }

    #[must_use]
    pub fn report(&self) -> &str {
        match self {
            Self::Succeeded => "renewal succeeded",
            Self::Failed { report } => report,
        }
    }
}
