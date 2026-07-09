use std::sync::Arc;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, Error as TlsError, SignatureScheme};
use tokio::net::{TcpStream, lookup_host};
use tokio_rustls::TlsConnector;
use x509_parser::parse_x509_certificate;

use super::{Http01ChallengeServer, TlsAlpn01ChallengeServer, validate_http01_material};

#[test]
fn http01_material_rejects_non_base64url_route_tokens() {
    for token in ["{capture}", ":parameter", "token%2fescape", "token.value"] {
        assert!(
            validate_http01_material(token, "key-authorization").is_err(),
            "accepted invalid HTTP-01 token: {token}"
        );
    }
    assert!(validate_http01_material("valid_TOKEN-123", "key-authorization").is_ok());
}

#[tokio::test]
async fn http01_server_serves_only_the_exact_challenge_token() {
    let server = Http01ChallengeServer::start(
        "127.0.0.1",
        0,
        "exact-token",
        "exact-token.account-thumbprint",
    )
    .await
    .expect("start HTTP-01 server");
    let addr = server.local_addr();
    let client = reqwest::Client::new();

    let exact = client
        .get(format!(
            "http://{addr}/.well-known/acme-challenge/exact-token"
        ))
        .send()
        .await
        .expect("request exact challenge");
    assert_eq!(exact.status(), reqwest::StatusCode::OK);
    assert_eq!(
        exact.text().await.expect("read challenge body"),
        "exact-token.account-thumbprint"
    );

    for path in [
        "/.well-known/acme-challenge/wrong-token",
        "/.well-known/acme-challenge/exact-token/extra",
        "/v1/ready",
    ] {
        let response = client
            .get(format!("http://{addr}{path}"))
            .send()
            .await
            .expect("request rejected path");
        assert_eq!(response.status(), reqwest::StatusCode::NOT_FOUND);
    }

    server.stop().await.expect("stop HTTP-01 server");
    assert!(TcpStream::connect(addr).await.is_err());
}

#[tokio::test]
async fn tls_alpn01_server_negotiates_acme_protocol_and_digest_certificate() {
    let digest = [0x5a; 32];
    let server = TlsAlpn01ChallengeServer::start("127.0.0.1", 0, "daemon.example.com", &digest)
        .await
        .expect("start TLS-ALPN-01 server");
    let addr = server.local_addr();
    let certificate = server.certificate_der();
    let mut client_config = ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(NoCertificateVerification))
        .with_no_client_auth();
    client_config.alpn_protocols = vec![b"acme-tls/1".to_vec()];
    let connector = TlsConnector::from(Arc::new(client_config));
    let tcp = TcpStream::connect(addr)
        .await
        .expect("connect challenge TCP");
    let server_name = ServerName::try_from("daemon.example.com".to_string())
        .expect("valid challenge server name");
    let tls = connector
        .connect(server_name, tcp)
        .await
        .expect("complete challenge TLS handshake");

    assert_eq!(
        tls.get_ref().1.alpn_protocol(),
        Some(b"acme-tls/1".as_slice())
    );
    let (_, parsed) = parse_x509_certificate(&certificate).expect("parse challenge certificate");
    let extension = parsed
        .extensions()
        .iter()
        .find(|extension| extension.oid.to_id_string() == "1.3.6.1.5.5.7.1.31")
        .expect("acmeIdentifier extension");
    assert!(extension.critical);
    let expected_value = [vec![0x04, 0x20], digest.to_vec()].concat();
    assert_eq!(extension.value, expected_value);

    drop(tls);
    server.stop().await.expect("stop TLS-ALPN-01 server");
    assert!(lookup_host(addr).await.is_ok());
    assert!(TcpStream::connect(addr).await.is_err());
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
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
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
