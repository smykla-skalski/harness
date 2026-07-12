use std::error::Error;
use std::fmt;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};

use super::remote_acme::RemoteCertificateBundle;
use arc_swap::ArcSwap;
use rcgen::{CertificateParams, CustomExtension, DistinguishedName, KeyPair};
use rustls::ServerConfig;
use rustls::crypto::ring::default_provider;
use rustls::crypto::ring::sign::any_supported_type;
use rustls::pki_types::pem::PemObject as _;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::server::{ClientHello, ResolvesServerCert};
use rustls::sign::CertifiedKey;

mod listener;
pub use listener::RemoteTlsListener;
pub(crate) use listener::{DEFAULT_MAX_CONCURRENT_TLS_HANDSHAKES, DEFAULT_TLS_HANDSHAKE_TIMEOUT};
#[cfg(test)]
use listener::{handle_tcp_accept_error, handle_tls_handshake_error, is_transient_accept_error};

#[cfg(test)]
#[path = "remote_tls_live_tests.rs"]
mod live_tests;
#[cfg(test)]
#[path = "remote_tls_tests.rs"]
mod tests;

static RUSTLS_PROVIDER: OnceLock<()> = OnceLock::new();

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteTlsConfigError {
    MissingCertificate,
    MissingPrivateKey,
    InvalidCertificatePem(String),
    InvalidPrivateKeyPem(String),
    InvalidServerConfig(String),
    InvalidAcmeChallenge(String),
}

impl fmt::Display for RemoteTlsConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingCertificate => write!(f, "remote TLS certificate PEM is required"),
            Self::MissingPrivateKey => write!(f, "remote TLS private key PEM is required"),
            Self::InvalidCertificatePem(error) => {
                write!(f, "remote TLS certificate PEM is invalid: {error}")
            }
            Self::InvalidPrivateKeyPem(error) => {
                write!(f, "remote TLS private key PEM is invalid: {error}")
            }
            Self::InvalidServerConfig(error) => {
                write!(f, "remote TLS server config is invalid: {error}")
            }
            Self::InvalidAcmeChallenge(error) => {
                write!(f, "remote TLS ACME challenge is invalid: {error}")
            }
        }
    }
}

impl Error for RemoteTlsConfigError {}

/// Build the rustls server config used by the internet-facing daemon listener.
///
/// # Errors
/// Returns [`RemoteTlsConfigError`] when the persisted ACME certificate bundle
/// is missing, malformed, or rejected by rustls.
pub fn build_remote_tls_server_config(
    bundle: &RemoteCertificateBundle,
) -> Result<Arc<ServerConfig>, RemoteTlsConfigError> {
    build_remote_tls_server_config_with_challenge(bundle, None)
}

fn build_remote_tls_server_config_with_challenge(
    bundle: &RemoteCertificateBundle,
    challenge: Option<&ActiveRemoteTlsAlpnChallenge>,
) -> Result<Arc<ServerConfig>, RemoteTlsConfigError> {
    ensure_rustls_provider();
    let normal = certified_key_from_bundle(bundle)?;
    let resolver = RemoteTlsCertificateResolver {
        normal,
        challenge: challenge.cloned(),
    };
    let mut config = ServerConfig::builder()
        .with_no_client_auth()
        .with_cert_resolver(Arc::new(resolver));
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    if challenge.is_some() {
        config.alpn_protocols.insert(0, b"acme-tls/1".to_vec());
    }
    Ok(Arc::new(config))
}

fn certified_key_from_bundle(
    bundle: &RemoteCertificateBundle,
) -> Result<Arc<CertifiedKey>, RemoteTlsConfigError> {
    let cert_chain = parse_certificate_chain(bundle.certificate_pem())?;
    let private_key = parse_private_key(bundle.private_key_pem())?;
    let certified_key = CertifiedKey::from_der(cert_chain, private_key, &default_provider())
        .map_err(|error| RemoteTlsConfigError::InvalidServerConfig(error.to_string()))?;
    Ok(Arc::new(certified_key))
}

struct RemoteTlsConfigState {
    bundle: RemoteCertificateBundle,
    generation: u64,
    challenge: Option<ActiveRemoteTlsAlpnChallenge>,
    next_challenge_id: u64,
}

#[derive(Clone)]
struct ActiveRemoteTlsAlpnChallenge {
    id: u64,
    domain: String,
    certified_key: Arc<CertifiedKey>,
}

impl fmt::Debug for ActiveRemoteTlsAlpnChallenge {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ActiveRemoteTlsAlpnChallenge")
            .field("id", &self.id)
            .field("domain", &self.domain)
            .finish_non_exhaustive()
    }
}

#[derive(Debug)]
struct RemoteTlsCertificateResolver {
    normal: Arc<CertifiedKey>,
    challenge: Option<ActiveRemoteTlsAlpnChallenge>,
}

impl ResolvesServerCert for RemoteTlsCertificateResolver {
    fn resolve(&self, client_hello: ClientHello<'_>) -> Option<Arc<CertifiedKey>> {
        let offers_acme_alpn = client_hello
            .alpn()
            .is_some_and(|mut protocols| protocols.any(|protocol| protocol == b"acme-tls/1"));
        if offers_acme_alpn
            && let Some(challenge) = self.challenge.as_ref()
            && remote_tls_server_name_matches(client_hello.server_name(), &challenge.domain)
        {
            return Some(Arc::clone(&challenge.certified_key));
        }
        Some(Arc::clone(&self.normal))
    }
}

fn remote_tls_server_name_matches(server_name: Option<&str>, expected_domain: &str) -> bool {
    server_name.is_some_and(|name| name.eq_ignore_ascii_case(expected_domain))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct RemoteTlsAlpnChallengeLease {
    id: u64,
}

pub(crate) struct RemoteTlsAlpnChallengeCertificate {
    certified_key: Arc<CertifiedKey>,
    certificate_der: Vec<u8>,
}

impl RemoteTlsAlpnChallengeCertificate {
    pub(crate) fn certified_key(&self) -> Arc<CertifiedKey> {
        Arc::clone(&self.certified_key)
    }

    pub(crate) fn certificate_der(&self) -> Vec<u8> {
        self.certificate_der.clone()
    }
}

pub(crate) fn build_remote_tls_alpn_challenge(
    domain: &str,
    digest: &[u8],
) -> Result<RemoteTlsAlpnChallengeCertificate, String> {
    let domain = domain.trim();
    if domain.is_empty() {
        return Err("remote ACME TLS-ALPN-01 domain is required".to_string());
    }
    if digest.len() != 32 {
        return Err("remote ACME TLS-ALPN-01 digest must contain 32 bytes".to_string());
    }
    ensure_rustls_provider();
    let key = KeyPair::generate()
        .map_err(|error| format!("generate remote ACME TLS-ALPN-01 key: {error}"))?;
    let mut params = CertificateParams::new([domain.to_string()])
        .map_err(|error| format!("build remote ACME TLS-ALPN-01 certificate: {error}"))?;
    params.distinguished_name = DistinguishedName::new();
    params
        .custom_extensions
        .push(CustomExtension::new_acme_identifier(digest));
    let certificate = params
        .self_signed(&key)
        .map_err(|error| format!("sign remote ACME TLS-ALPN-01 certificate: {error}"))?;
    let certificate_der = certificate.der().to_vec();
    let private_key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der()));
    let signing_key = any_supported_type(&private_key)
        .map_err(|error| format!("load remote ACME TLS-ALPN-01 key: {error}"))?;
    Ok(RemoteTlsAlpnChallengeCertificate {
        certified_key: Arc::new(CertifiedKey::new(
            vec![CertificateDer::from(certificate_der.clone())],
            signing_key,
        )),
        certificate_der,
    })
}

#[derive(Clone)]
pub(crate) struct RemoteTlsConfigHandle {
    config: Arc<ArcSwap<ServerConfig>>,
    state: Arc<Mutex<RemoteTlsConfigState>>,
}

impl RemoteTlsConfigHandle {
    pub(crate) fn new(bundle: RemoteCertificateBundle) -> Result<Self, RemoteTlsConfigError> {
        let config = build_remote_tls_server_config(&bundle)?;
        Ok(Self {
            config: Arc::new(ArcSwap::from(config)),
            state: Arc::new(Mutex::new(RemoteTlsConfigState {
                bundle,
                generation: 1,
                challenge: None,
                next_challenge_id: 1,
            })),
        })
    }

    pub(crate) fn generation(&self) -> u64 {
        self.lock_state().generation
    }

    pub(crate) fn certificate_fingerprint(&self) -> String {
        self.lock_state().bundle.fingerprint().to_string()
    }

    #[cfg(test)]
    pub(crate) fn tls_alpn_challenge_active(&self) -> bool {
        self.lock_state().challenge.is_some()
    }

    pub(crate) fn reload(
        &self,
        bundle: RemoteCertificateBundle,
    ) -> Result<bool, RemoteTlsConfigError> {
        let mut state = self.lock_state();
        if state.bundle.fingerprint() == bundle.fingerprint() {
            return Ok(false);
        }
        let config =
            build_remote_tls_server_config_with_challenge(&bundle, state.challenge.as_ref())?;
        state.bundle = bundle;
        state.generation += 1;
        self.config.store(config);
        Ok(true)
    }

    pub(crate) fn present_tls_alpn_challenge(
        &self,
        domain: &str,
        digest: &[u8],
    ) -> Result<RemoteTlsAlpnChallengeLease, RemoteTlsConfigError> {
        let certificate = build_remote_tls_alpn_challenge(domain, digest)
            .map_err(RemoteTlsConfigError::InvalidAcmeChallenge)?;
        let mut state = self.lock_state();
        if state.challenge.is_some() {
            return Err(RemoteTlsConfigError::InvalidAcmeChallenge(
                "another TLS-ALPN-01 challenge is already active".to_string(),
            ));
        }
        let lease = RemoteTlsAlpnChallengeLease {
            id: state.next_challenge_id,
        };
        let challenge = ActiveRemoteTlsAlpnChallenge {
            id: lease.id,
            domain: domain.trim().to_string(),
            certified_key: certificate.certified_key(),
        };
        let config =
            build_remote_tls_server_config_with_challenge(&state.bundle, Some(&challenge))?;
        state.next_challenge_id = state.next_challenge_id.saturating_add(1);
        state.challenge = Some(challenge);
        self.config.store(config);
        Ok(lease)
    }

    pub(crate) fn clear_tls_alpn_challenge(
        &self,
        lease: RemoteTlsAlpnChallengeLease,
    ) -> Result<(), RemoteTlsConfigError> {
        let mut state = self.lock_state();
        let Some(challenge) = state.challenge.as_ref() else {
            return Ok(());
        };
        if challenge.id != lease.id {
            return Err(RemoteTlsConfigError::InvalidAcmeChallenge(
                "TLS-ALPN-01 challenge lease does not match the active challenge".to_string(),
            ));
        }
        let config = build_remote_tls_server_config_with_challenge(&state.bundle, None)?;
        state.challenge = None;
        self.config.store(config);
        Ok(())
    }

    fn config_source(&self) -> Arc<ArcSwap<ServerConfig>> {
        Arc::clone(&self.config)
    }

    fn lock_state(&self) -> MutexGuard<'_, RemoteTlsConfigState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

fn parse_certificate_chain(
    pem: &str,
) -> Result<Vec<CertificateDer<'static>>, RemoteTlsConfigError> {
    if pem.trim().is_empty() {
        return Err(RemoteTlsConfigError::MissingCertificate);
    }
    let certs = CertificateDer::pem_slice_iter(pem.as_bytes())
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| RemoteTlsConfigError::InvalidCertificatePem(error.to_string()))?;
    if certs.is_empty() {
        return Err(RemoteTlsConfigError::InvalidCertificatePem(
            "no certificate PEM blocks found".to_string(),
        ));
    }
    Ok(certs)
}

fn parse_private_key(pem: &str) -> Result<PrivateKeyDer<'static>, RemoteTlsConfigError> {
    if pem.trim().is_empty() {
        return Err(RemoteTlsConfigError::MissingPrivateKey);
    }
    PrivateKeyDer::from_pem_slice(pem.as_bytes())
        .map_err(|error| RemoteTlsConfigError::InvalidPrivateKeyPem(error.to_string()))
}

pub(crate) fn ensure_rustls_provider() {
    RUSTLS_PROVIDER.get_or_init(install_remote_tls_rustls_provider);
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn install_remote_tls_rustls_provider() {
    if default_provider().install_default().is_err() {
        tracing::warn!("rustls crypto provider was already installed before remote TLS setup");
    }
}
