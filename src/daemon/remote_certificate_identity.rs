use std::error::Error;
use std::fmt;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use chrono::{DateTime, Utc};
use rustls::pki_types::CertificateDer;
use rustls::pki_types::pem::PemObject as _;
use sha2::{Digest, Sha256};
use x509_parser::certificate::X509Certificate;
use x509_parser::parse_x509_certificate;

use super::remote_acme::RemoteCertificateBundle;

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct RemotePrivateKeyPem(String);

impl RemotePrivateKeyPem {
    pub(crate) fn new(value: &str) -> Self {
        Self(value.to_string())
    }

    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for RemotePrivateKeyPem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("<redacted>")
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RemoteCertificateIdentityError {
    MissingCertificatePem,
    InvalidCertificatePem(String),
    InvalidCertificateDer(String),
}

impl fmt::Display for RemoteCertificateIdentityError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingCertificatePem => {
                write!(f, "remote certificate PEM contains no certificate block")
            }
            Self::InvalidCertificatePem(error) => {
                write!(f, "remote certificate PEM is invalid: {error}")
            }
            Self::InvalidCertificateDer(error) => {
                write!(f, "remote certificate DER is invalid: {error}")
            }
        }
    }
}

impl Error for RemoteCertificateIdentityError {}

pub(crate) fn spki_sha256_pin(
    bundle: &RemoteCertificateBundle,
) -> Result<String, RemoteCertificateIdentityError> {
    inspect_leaf_certificate(bundle, |certificate| {
        let digest = Sha256::digest(certificate.public_key().raw);
        format!("sha256/{}", STANDARD.encode(digest))
    })
}

pub(crate) fn certificate_not_after(
    bundle: &RemoteCertificateBundle,
) -> Result<DateTime<Utc>, RemoteCertificateIdentityError> {
    inspect_leaf_certificate(bundle, |certificate| {
        certificate.validity().not_after.timestamp()
    })
    .and_then(|timestamp| {
        DateTime::from_timestamp(timestamp, 0).ok_or_else(|| {
            RemoteCertificateIdentityError::InvalidCertificateDer(
                "certificate expiry is outside the supported time range".to_string(),
            )
        })
    })
}

fn inspect_leaf_certificate<T, Inspect>(
    bundle: &RemoteCertificateBundle,
    inspect: Inspect,
) -> Result<T, RemoteCertificateIdentityError>
where
    Inspect: FnOnce(&X509Certificate<'_>) -> T,
{
    let certificate = CertificateDer::pem_slice_iter(bundle.certificate_pem().as_bytes())
        .next()
        .ok_or(RemoteCertificateIdentityError::MissingCertificatePem)?
        .map_err(|error| {
            RemoteCertificateIdentityError::InvalidCertificatePem(error.to_string())
        })?;
    let (remainder, certificate) =
        parse_x509_certificate(certificate.as_ref()).map_err(|error| {
            RemoteCertificateIdentityError::InvalidCertificateDer(error.to_string())
        })?;
    if !remainder.is_empty() {
        return Err(RemoteCertificateIdentityError::InvalidCertificateDer(
            "trailing certificate data".to_string(),
        ));
    }
    Ok(inspect(&certificate))
}
