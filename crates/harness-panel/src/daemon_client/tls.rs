//! Talking to the daemon over a connection whose key the panel already knows.
//!
//! The daemon publishes the SHA-256 of its certificate's public key in every
//! pairing invitation it issues, and the operator hands the panel that same
//! value. Checking it on each connection means a certificate some other
//! authority issued for the daemon's name is refused even though its chain
//! validates, which is the case ordinary verification cannot see.
//!
//! This duplicates a verifier the root `harness` crate already has. It has to:
//! the panel is barred from depending on that crate, which is the whole reason
//! it talks to the daemon over HTTP.

use std::fmt;
use std::sync::Arc;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::ring;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{CertificateError, ClientConfig, DigitallySignedStruct, Error, SignatureScheme};
use rustls_platform_verifier::Verifier;
use sha2::{Digest, Sha256};
use x509_parser::certificate::X509Certificate;
use x509_parser::prelude::FromDer;

use crate::error::PanelError;

/// The `sha256/` prefix the daemon writes its pin with, matching the value in a
/// pairing invitation so an operator can copy one across without translating.
const PIN_PREFIX: &str = "sha256/";

/// The SHA-256 of the daemon certificate's subject public key.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct SpkiPin {
    digest: [u8; 32],
}

impl SpkiPin {
    /// Parse the `sha256/<base64>` form the daemon publishes.
    ///
    /// # Errors
    /// Returns [`PanelError::Config`] when the value is not that form.
    pub fn parse(value: &str) -> Result<Self, PanelError> {
        let refuse = || {
            PanelError::config(format!(
                "--daemon-spki-pin must look like sha256/<base64 of 32 bytes>, got {value:?}"
            ))
        };
        let encoded = value.trim().strip_prefix(PIN_PREFIX).ok_or_else(refuse)?;
        let digest: [u8; 32] = STANDARD
            .decode(encoded)
            .map_err(|_| refuse())?
            .try_into()
            .map_err(|_| refuse())?;
        Ok(Self { digest })
    }

    #[must_use]
    pub fn to_pin_string(&self) -> String {
        format!("{PIN_PREFIX}{}", STANDARD.encode(self.digest))
    }
}

/// The pin identifies the daemon, so printing it is harmless, but printing it
/// by accident inside a config dump is noise; the shape is what matters.
impl fmt::Debug for SpkiPin {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SpkiPin")
            .field("pin", &self.to_pin_string())
            .finish()
    }
}

/// Build a TLS configuration that trusts the daemon and nothing else wearing
/// its name.
///
/// # Errors
/// Returns [`PanelError::Config`] when the platform's own verifier cannot be
/// built, which leaves the panel unable to check a chain at all.
pub fn pinned_client_config(pin: SpkiPin) -> Result<ClientConfig, PanelError> {
    let provider = Arc::new(ring::default_provider());
    let platform = Verifier::new(Arc::clone(&provider)).map_err(|error| {
        PanelError::config(format!("the platform TLS verifier is unavailable: {error}"))
    })?;

    let config = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|error| PanelError::config(format!("TLS protocol versions: {error}")))?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(PinnedVerifier {
            inner: Arc::new(platform),
            expected: pin,
        }))
        .with_no_client_auth();
    Ok(config)
}

/// Ordinary verification plus the pin.
///
/// Both, not either: the pin alone would accept an expired certificate or one
/// issued for another name, and the chain alone is what this exists to
/// strengthen.
#[derive(Debug)]
struct PinnedVerifier {
    inner: Arc<Verifier>,
    expected: SpkiPin,
}

impl ServerCertVerifier for PinnedVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &ServerName<'_>,
        ocsp_response: &[u8],
        now: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        // The pin is checked first so a certificate that is not the daemon's
        // fails as a pin mismatch rather than as whatever the chain says about
        // it, which is the difference between a clear message and a confusing
        // one when an operator has copied the wrong pin.
        let presented = spki_sha256(end_entity)?;
        if presented != self.expected.digest {
            return Err(Error::InvalidCertificate(
                CertificateError::ApplicationVerificationFailure,
            ));
        }
        self.inner
            .verify_server_cert(end_entity, intermediates, server_name, ocsp_response, now)
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        self.inner.verify_tls12_signature(message, cert, dss)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        self.inner.verify_tls13_signature(message, cert, dss)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.inner.supported_verify_schemes()
    }
}

fn spki_sha256(certificate: &CertificateDer<'_>) -> Result<[u8; 32], Error> {
    let (_, parsed) = X509Certificate::from_der(certificate.as_ref())
        .map_err(|_| Error::InvalidCertificate(CertificateError::BadEncoding))?;
    Ok(Sha256::digest(parsed.public_key().raw).into())
}

#[cfg(test)]
mod tests {
    use super::{PIN_PREFIX, SpkiPin};
    use base64::Engine as _;
    use base64::engine::general_purpose::STANDARD;

    #[test]
    fn a_pin_round_trips_through_the_form_the_daemon_publishes() {
        let digest = [7_u8; 32];
        let encoded = format!("{PIN_PREFIX}{}", STANDARD.encode(digest));

        let pin = SpkiPin::parse(&encoded).expect("a valid pin");

        assert_eq!(pin.to_pin_string(), encoded);
    }

    #[test]
    fn surrounding_whitespace_is_tolerated() {
        let encoded = format!("{PIN_PREFIX}{}", STANDARD.encode([1_u8; 32]));

        assert!(SpkiPin::parse(&format!("  {encoded}  ")).is_ok());
    }

    /// A pin that parses to the wrong length would silently compare against a
    /// digest the panel never received.
    #[test]
    fn a_malformed_pin_is_refused() {
        for raw in [
            "",
            "deadbeef",
            "sha256/",
            "sha256/not base64",
            &format!("{PIN_PREFIX}{}", STANDARD.encode([0_u8; 31])),
            &format!("{PIN_PREFIX}{}", STANDARD.encode([0_u8; 33])),
            &STANDARD.encode([0_u8; 32]),
        ] {
            let error = SpkiPin::parse(raw).expect_err("a malformed pin must be refused");
            assert!(error.to_string().contains("--daemon-spki-pin"), "{raw}");
        }
    }

    #[test]
    fn two_different_certificates_do_not_share_a_pin() {
        let first = SpkiPin::parse(&format!("{PIN_PREFIX}{}", STANDARD.encode([1_u8; 32])))
            .expect("a valid pin");
        let second = SpkiPin::parse(&format!("{PIN_PREFIX}{}", STANDARD.encode([2_u8; 32])))
            .expect("a valid pin");

        assert_ne!(first, second);
    }
}
