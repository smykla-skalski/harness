use std::error::Error;
use std::fmt;
use std::sync::Arc;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{
    CertificateError, ClientConfig, DigitallySignedStruct, DistinguishedName, SignatureScheme,
};
use rustls_platform_verifier::Verifier;

use crate::daemon::remote_certificate_identity::spki_sha256_digest_from_der;
use crate::task_board::remote_spki_pin;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemoteTlsPinError {
    InvalidPin,
    PlatformVerifier,
    ClientConfiguration,
}

impl fmt::Display for RemoteTlsPinError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidPin => write!(formatter, "remote SPKI SHA-256 pin is invalid"),
            Self::PlatformVerifier => write!(formatter, "platform TLS verifier is unavailable"),
            Self::ClientConfiguration => {
                write!(formatter, "remote TLS client configuration failed")
            }
        }
    }
}

impl Error for RemoteTlsPinError {}

pub(super) fn pinned_platform_client_config(
    expected_spki_sha256: &str,
) -> Result<ClientConfig, RemoteTlsPinError> {
    #[cfg(test)]
    if let Some(roots) = test_extra_roots()? {
        return pinned_client_config_with_roots(expected_spki_sha256, roots);
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let platform =
        Verifier::new(Arc::clone(&provider)).map_err(|_| RemoteTlsPinError::PlatformVerifier)?;
    pinned_client_config(expected_spki_sha256, Arc::new(platform), provider)
}

#[cfg(test)]
const TEST_EXTRA_ROOTS_HEX_ENV: &str = "HARNESS_TEST_REMOTE_TLS_ROOTS_HEX";

#[cfg(test)]
fn test_extra_roots() -> Result<Option<Vec<CertificateDer<'static>>>, RemoteTlsPinError> {
    let Some(encoded) = std::env::var_os(TEST_EXTRA_ROOTS_HEX_ENV) else {
        return Ok(None);
    };
    let encoded = encoded
        .into_string()
        .map_err(|_| RemoteTlsPinError::PlatformVerifier)?;
    let bytes = hex::decode(encoded).map_err(|_| RemoteTlsPinError::PlatformVerifier)?;
    if bytes.is_empty() {
        return Err(RemoteTlsPinError::PlatformVerifier);
    }
    Ok(Some(vec![CertificateDer::from(bytes)]))
}

#[cfg(test)]
pub(crate) const fn test_extra_roots_env() -> &'static str {
    TEST_EXTRA_ROOTS_HEX_ENV
}

#[cfg(test)]
pub(super) fn pinned_client_config_with_roots(
    expected_spki_sha256: &str,
    roots: Vec<CertificateDer<'static>>,
) -> Result<ClientConfig, RemoteTlsPinError> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let verifier = Verifier::new_with_extra_roots(roots, Arc::clone(&provider))
        .map_err(|_| RemoteTlsPinError::PlatformVerifier)?;
    pinned_client_config(expected_spki_sha256, Arc::new(verifier), provider)
}

fn pinned_client_config(
    expected_spki_sha256: &str,
    verifier: Arc<dyn ServerCertVerifier>,
    provider: Arc<rustls::crypto::CryptoProvider>,
) -> Result<ClientConfig, RemoteTlsPinError> {
    let expected =
        remote_spki_pin::decode(expected_spki_sha256).ok_or(RemoteTlsPinError::InvalidPin)?;
    ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|_| RemoteTlsPinError::ClientConfiguration)
        .map(|builder| {
            builder
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(SpkiPinVerifier {
                    expected,
                    platform: verifier,
                }))
                .with_no_client_auth()
        })
}

struct SpkiPinVerifier {
    expected: [u8; 32],
    platform: Arc<dyn ServerCertVerifier>,
}

impl fmt::Debug for SpkiPinVerifier {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SpkiPinVerifier")
            .field("expected", &"<configured SPKI sha256 pin>")
            .finish_non_exhaustive()
    }
}

impl ServerCertVerifier for SpkiPinVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &ServerName<'_>,
        ocsp_response: &[u8],
        now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let verified = self.platform.verify_server_cert(
            end_entity,
            intermediates,
            server_name,
            ocsp_response,
            now,
        )?;
        let observed = spki_sha256_digest_from_der(end_entity.as_ref()).map_err(|_| {
            rustls::Error::InvalidCertificate(CertificateError::ApplicationVerificationFailure)
        })?;
        if observed != self.expected {
            return Err(rustls::Error::InvalidCertificate(
                CertificateError::ApplicationVerificationFailure,
            ));
        }
        Ok(verified)
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        self.platform
            .verify_tls12_signature(message, cert, signature)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        self.platform
            .verify_tls13_signature(message, cert, signature)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.platform.supported_verify_schemes()
    }

    fn requires_raw_public_keys(&self) -> bool {
        self.platform.requires_raw_public_keys()
    }

    fn root_hint_subjects(&self) -> Option<&[DistinguishedName]> {
        self.platform.root_hint_subjects()
    }
}
