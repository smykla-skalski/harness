use std::fs;
use std::path::Path;
use std::sync::Arc;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, Error as TlsError, SignatureScheme};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::TcpStream;
use tokio_rustls::TlsConnector;
use x509_parser::parse_x509_certificate;

use super::{AcmeChallenge, AcmeChallengeConfig, HTTP_TOKEN};

pub(super) async fn verify_challenge(config: &AcmeChallengeConfig) -> Result<(), String> {
    match config.challenge {
        AcmeChallenge::Http => verify_http_challenge(config).await,
        AcmeChallenge::TlsAlpn => verify_tls_alpn_challenge(config).await,
        AcmeChallenge::Dns => verify_dns_challenge(config),
    }
}

async fn verify_http_challenge(config: &AcmeChallengeConfig) -> Result<(), String> {
    let mut stream = TcpStream::connect(("127.0.0.1", config.http_port))
        .await
        .map_err(|error| format!("connect HTTP-01 challenge: {error}"))?;
    let request = format!(
        "GET /.well-known/acme-challenge/{HTTP_TOKEN} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n",
        config.domain
    );
    stream
        .write_all(request.as_bytes())
        .await
        .map_err(|error| format!("write HTTP-01 challenge request: {error}"))?;
    let mut response = String::new();
    stream
        .read_to_string(&mut response)
        .await
        .map_err(|error| format!("read HTTP-01 challenge response: {error}"))?;
    let body = response
        .split_once("\r\n\r\n")
        .map(|(_, body)| body.trim())
        .unwrap_or_default();
    if !response.starts_with("HTTP/1.1 200") || !body.starts_with(&format!("{HTTP_TOKEN}.")) {
        return Err(format!(
            "HTTP-01 challenge response was invalid: {response}"
        ));
    }
    Ok(())
}

async fn verify_tls_alpn_challenge(config: &AcmeChallengeConfig) -> Result<(), String> {
    let mut tls_config = ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(NoCertificateVerification))
        .with_no_client_auth();
    tls_config.alpn_protocols = vec![b"acme-tls/1".to_vec()];
    let stream = TcpStream::connect(("127.0.0.1", config.https_port))
        .await
        .map_err(|error| format!("connect TLS-ALPN-01 challenge: {error}"))?;
    let server_name = ServerName::try_from(config.domain.clone())
        .map_err(|error| format!("build TLS-ALPN-01 server name: {error}"))?;
    let stream = TlsConnector::from(Arc::new(tls_config))
        .connect(server_name, stream)
        .await
        .map_err(|error| format!("handshake TLS-ALPN-01 challenge: {error}"))?;
    if stream.get_ref().1.alpn_protocol() != Some(b"acme-tls/1".as_slice()) {
        return Err("TLS-ALPN-01 challenge did not negotiate acme-tls/1".to_string());
    }
    let certificate = stream
        .get_ref()
        .1
        .peer_certificates()
        .and_then(|certificates| certificates.first())
        .ok_or_else(|| "TLS-ALPN-01 challenge omitted certificate".to_string())?;
    let (_, certificate) = parse_x509_certificate(certificate)
        .map_err(|error| format!("parse TLS-ALPN-01 certificate: {error}"))?;
    let extension = certificate
        .extensions()
        .iter()
        .find(|extension| extension.oid.to_id_string() == "1.3.6.1.5.5.7.1.31")
        .ok_or_else(|| "TLS-ALPN-01 certificate omitted acmeIdentifier".to_string())?;
    if !extension.critical || extension.value.len() != 34 || extension.value[..2] != [0x04, 0x20] {
        return Err("TLS-ALPN-01 acmeIdentifier extension was invalid".to_string());
    }
    Ok(())
}

fn verify_dns_challenge(config: &AcmeChallengeConfig) -> Result<(), String> {
    let log = fs::read_to_string(&config.dns_log)
        .map_err(|error| format!("read DNS-01 hook log: {error}"))?;
    let prefix = format!("present|_acme-challenge.{}|", config.domain);
    if log
        .lines()
        .any(|line| line.starts_with(&prefix) && line.len() > prefix.len())
    {
        return Ok(());
    }
    Err(format!(
        "DNS-01 hook did not present the TXT value: {log:?}"
    ))
}

pub(super) fn dns_lifecycle_complete(path: &Path) -> Result<bool, String> {
    let log = match fs::read_to_string(path) {
        Ok(log) => log,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(format!("read DNS-01 lifecycle log: {error}")),
    };
    let mut present = None;
    let mut cleanup = None;
    for line in log.lines() {
        if let Some(value) = line.strip_prefix("present|") {
            present = Some(value);
        } else if let Some(value) = line.strip_prefix("cleanup|") {
            cleanup = Some(value);
        }
    }
    Ok(present.is_some() && present == cleanup)
}

#[derive(Debug)]
struct NoCertificateVerification;

impl ServerCertVerifier for NoCertificateVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, TlsError> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _certificate: &CertificateDer<'_>,
        _signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _certificate: &CertificateDer<'_>,
        _signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::ED25519,
        ]
    }
}
