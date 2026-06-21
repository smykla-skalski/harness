use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;

use sha2::{Digest, Sha256};

use super::protocol::http_paths;
use super::remote::{
    RemoteAcmeChallenge, RemoteDaemonConfigError, RemoteDaemonServeConfig, RemoteDnsProvider,
    validate_remote_serve_config,
};

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
pub struct Dns01ProviderAction {
    provider: RemoteDnsProvider,
    fqdn: String,
    digest: String,
}

impl Dns01ProviderAction {
    #[must_use]
    pub fn for_provider(
        provider: RemoteDnsProvider,
        fqdn: impl Into<String>,
        digest: impl Into<String>,
    ) -> Self {
        Self {
            provider,
            fqdn: fqdn.into(),
            digest: digest.into(),
        }
    }

    #[must_use]
    pub const fn required_secret_names(&self) -> &'static [&'static str] {
        match self.provider {
            RemoteDnsProvider::Cloudflare => &["CLOUDFLARE_API_TOKEN"],
            RemoteDnsProvider::Route53 => &["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"],
            RemoteDnsProvider::Exec => &["HARNESS_REMOTE_ACME_DNS_EXEC"],
        }
    }

    #[must_use]
    pub fn command_preview(&self) -> String {
        match self.provider {
            RemoteDnsProvider::Cloudflare => {
                format!("cloudflare TXT {} {}", self.fqdn, self.digest)
            }
            RemoteDnsProvider::Route53 => format!("route53 TXT {} {}", self.fqdn, self.digest),
            RemoteDnsProvider::Exec => {
                format!(
                    "$HARNESS_REMOTE_ACME_DNS_EXEC present {} {}",
                    self.fqdn, self.digest
                )
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteCertificateBundle {
    certificate_pem: String,
    private_key_pem: String,
    fingerprint: String,
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

fn redact_secret_detail(detail: &str) -> String {
    detail
        .split_whitespace()
        .map(|part| {
            if part.starts_with("secret=") || part.starts_with("token=") {
                "<redacted>".to_string()
            } else {
                part.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}
