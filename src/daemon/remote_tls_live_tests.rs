use std::net::SocketAddr;
use std::sync::Arc;

use axum::serve::Listener as _;
use rcgen::{CertificateParams, KeyPair};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, Error as TlsError, SignatureScheme};
use tokio::net::TcpStream;
use tokio::time::{Duration, sleep, timeout};
use tokio_rustls::TlsConnector;
use x509_parser::parse_x509_certificate;

use super::{RemoteTlsConfigHandle, RemoteTlsListener};
use crate::daemon::remote_acme::RemoteCertificateBundle;

#[tokio::test]
async fn remote_tls_listener_uses_reloaded_certificate_on_new_handshakes() {
    let (initial, initial_der) = generated_bundle("daemon.example.com");
    let (renewed, renewed_der) = generated_bundle("daemon.example.com");
    let handle = RemoteTlsConfigHandle::new(initial).expect("initial TLS config");
    let mut listener = RemoteTlsListener::bind_reloadable(("127.0.0.1", 0), &handle)
        .await
        .expect("bind reloadable TLS listener");
    let address = listener.local_addr().expect("TLS listener address");

    let first = connect_once(&mut listener, address, b"h2").await;
    assert_eq!(first.certificate_der, initial_der);

    assert!(handle.reload(renewed).expect("reload renewed certificate"));
    let second = connect_once(&mut listener, address, b"h2").await;
    assert_eq!(second.certificate_der, renewed_der);
    assert_ne!(second.certificate_der, first.certificate_der);
}

#[tokio::test]
async fn remote_tls_listener_serves_acme_alpn_challenge_without_disrupting_https() {
    let (normal, normal_der) = generated_bundle("daemon.example.com");
    let handle = RemoteTlsConfigHandle::new(normal).expect("initial TLS config");
    let mut listener = RemoteTlsListener::bind_reloadable(("127.0.0.1", 0), &handle)
        .await
        .expect("bind reloadable TLS listener");
    let address = listener.local_addr().expect("TLS listener address");
    let digest = [7_u8; 32];

    let lease = handle
        .present_tls_alpn_challenge("daemon.example.com", &digest)
        .expect("publish TLS-ALPN-01 challenge");
    let challenge = connect_once(&mut listener, address, b"acme-tls/1").await;
    assert_eq!(
        challenge.negotiated_alpn.as_deref(),
        Some(b"acme-tls/1".as_slice())
    );
    assert_ne!(challenge.certificate_der, normal_der);
    assert_acme_identifier(&challenge.certificate_der, &digest);

    let normal_during_challenge = connect_once(&mut listener, address, b"h2").await;
    assert_eq!(
        normal_during_challenge.negotiated_alpn.as_deref(),
        Some(b"h2".as_slice())
    );
    assert_eq!(normal_during_challenge.certificate_der, normal_der);

    handle
        .clear_tls_alpn_challenge(lease)
        .expect("clear TLS-ALPN-01 challenge");
    let normal_after_cleanup = connect_once(&mut listener, address, b"h2").await;
    assert_eq!(normal_after_cleanup.certificate_der, normal_der);
}

#[tokio::test]
async fn remote_tls_listener_falls_back_without_an_active_acme_challenge() {
    let (normal, normal_der) = generated_bundle("daemon.example.com");
    let handle = RemoteTlsConfigHandle::new(normal).expect("initial TLS config");
    let mut listener = RemoteTlsListener::bind_reloadable(("127.0.0.1", 0), &handle)
        .await
        .expect("bind reloadable TLS listener");
    let address = listener.local_addr().expect("TLS listener address");

    let handshake = timeout(
        Duration::from_secs(5),
        connect_once_for_server_name_with_alpns(
            &mut listener,
            address,
            &[b"acme-tls/1".as_slice(), b"h2".as_slice()],
            "daemon.example.com",
        ),
    )
    .await
    .expect("normal TLS fallback handshake timeout");

    assert_eq!(handshake.certificate_der, normal_der);
    assert_eq!(handshake.negotiated_alpn.as_deref(), Some(b"h2".as_slice()));
}

#[tokio::test]
async fn remote_tls_listener_falls_back_when_acme_challenge_sni_does_not_match() {
    let (normal, normal_der) = generated_bundle("daemon.example.com");
    let handle = RemoteTlsConfigHandle::new(normal).expect("initial TLS config");
    let mut listener = RemoteTlsListener::bind_reloadable(("127.0.0.1", 0), &handle)
        .await
        .expect("bind reloadable TLS listener");
    let address = listener.local_addr().expect("TLS listener address");
    let lease = handle
        .present_tls_alpn_challenge("challenge.example.com", &[7_u8; 32])
        .expect("publish TLS-ALPN-01 challenge");

    let handshake = timeout(
        Duration::from_secs(5),
        connect_once_for_server_name(&mut listener, address, b"acme-tls/1", "daemon.example.com"),
    )
    .await
    .expect("normal TLS fallback handshake timeout");

    assert_eq!(handshake.certificate_der, normal_der);
    handle
        .clear_tls_alpn_challenge(lease)
        .expect("clear TLS-ALPN-01 challenge");
}

#[tokio::test]
async fn remote_tls_listener_accepts_valid_client_while_another_handshake_stalls() {
    let (normal, _) = generated_bundle("daemon.example.com");
    let handle = RemoteTlsConfigHandle::new(normal).expect("initial TLS config");
    let mut listener = RemoteTlsListener::bind_reloadable(("127.0.0.1", 0), &handle)
        .await
        .expect("bind reloadable TLS listener");
    let address = listener.local_addr().expect("TLS listener address");
    let _stalled = TcpStream::connect(address)
        .await
        .expect("open stalled TLS connection");
    let alpn_protocols = [b"h2".as_slice()];

    let ((server_stream, _), client_stream) = timeout(Duration::from_secs(1), async {
        tokio::join!(
            listener.accept(),
            connect_client(address, &alpn_protocols, "daemon.example.com")
        )
    })
    .await
    .expect("valid TLS client was blocked by stalled handshake");

    client_stream.expect("complete valid TLS handshake");
    drop(server_stream);
}

#[tokio::test]
async fn remote_tls_listener_times_out_stalled_handshakes_at_capacity() {
    let (normal, _) = generated_bundle("daemon.example.com");
    let handle = RemoteTlsConfigHandle::new(normal).expect("initial TLS config");
    let mut listener = RemoteTlsListener::bind_reloadable_with_limits(
        ("127.0.0.1", 0),
        &handle,
        1,
        Duration::from_millis(50),
    )
    .await
    .expect("bind limited TLS listener");
    let address = listener.local_addr().expect("TLS listener address");
    let _stalled = TcpStream::connect(address)
        .await
        .expect("open stalled TLS connection");
    let alpn_protocols = [b"h2".as_slice()];

    let ((server_stream, _), client_stream) = timeout(Duration::from_secs(1), async {
        tokio::join!(
            listener.accept(),
            connect_client(address, &alpn_protocols, "daemon.example.com")
        )
    })
    .await
    .expect("stalled TLS handshake did not release capacity");

    client_stream.expect("complete valid TLS handshake after timeout");
    drop(server_stream);
}

#[tokio::test]
async fn remote_tls_listener_bounds_pending_handshake_tasks() {
    let (normal, _) = generated_bundle("daemon.example.com");
    let handle = RemoteTlsConfigHandle::new(normal).expect("initial TLS config");
    let mut listener = RemoteTlsListener::bind_reloadable_with_limits(
        ("127.0.0.1", 0),
        &handle,
        1,
        Duration::from_secs(5),
    )
    .await
    .expect("bind limited TLS listener");
    let address = listener.local_addr().expect("TLS listener address");
    let _first = TcpStream::connect(address)
        .await
        .expect("open first stalled TLS connection");
    let _second = TcpStream::connect(address)
        .await
        .expect("open second stalled TLS connection");
    let mut accept = Box::pin(listener.accept());

    tokio::select! {
        _ = &mut accept => panic!("stalled TLS handshake unexpectedly completed"),
        () = sleep(Duration::from_millis(50)) => {}
    }
    drop(accept);

    assert_eq!(listener.pending_handshake_count(), 1);
}

struct ClientHandshake {
    certificate_der: Vec<u8>,
    negotiated_alpn: Option<Vec<u8>>,
}

async fn connect_once(
    listener: &mut RemoteTlsListener,
    address: SocketAddr,
    alpn: &[u8],
) -> ClientHandshake {
    connect_once_for_server_name(listener, address, alpn, "daemon.example.com").await
}

async fn connect_once_for_server_name(
    listener: &mut RemoteTlsListener,
    address: SocketAddr,
    alpn: &[u8],
    server_name: &str,
) -> ClientHandshake {
    connect_once_for_server_name_with_alpns(listener, address, &[alpn], server_name).await
}

async fn connect_once_for_server_name_with_alpns(
    listener: &mut RemoteTlsListener,
    address: SocketAddr,
    alpn_protocols: &[&[u8]],
    server_name: &str,
) -> ClientHandshake {
    let server = listener.accept();
    let client = connect_client(address, alpn_protocols, server_name);
    let ((server_stream, _), client_stream) = tokio::join!(server, client);
    let client_stream = client_stream.expect("complete client TLS handshake");
    let certificate_der = client_stream
        .get_ref()
        .1
        .peer_certificates()
        .and_then(|certificates| certificates.first())
        .expect("server leaf certificate")
        .to_vec();
    let negotiated_alpn = client_stream
        .get_ref()
        .1
        .alpn_protocol()
        .map(<[u8]>::to_vec);
    drop(client_stream);
    drop(server_stream);
    ClientHandshake {
        certificate_der,
        negotiated_alpn,
    }
}

async fn connect_client(
    address: SocketAddr,
    alpn_protocols: &[&[u8]],
    server_name: &str,
) -> Result<tokio_rustls::client::TlsStream<TcpStream>, std::io::Error> {
    let mut config = ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(NoCertificateVerification))
        .with_no_client_auth();
    config.alpn_protocols = alpn_protocols
        .iter()
        .map(|protocol| (*protocol).to_vec())
        .collect();
    let connector = TlsConnector::from(Arc::new(config));
    let stream = TcpStream::connect(address).await?;
    let server_name = ServerName::try_from(server_name.to_string()).expect("valid TLS server name");
    connector.connect(server_name, stream).await
}

fn generated_bundle(domain: &str) -> (RemoteCertificateBundle, Vec<u8>) {
    let key = KeyPair::generate().expect("generate key");
    let certificate = CertificateParams::new([domain.to_string()])
        .expect("certificate params")
        .self_signed(&key)
        .expect("self-sign certificate");
    (
        RemoteCertificateBundle::new(certificate.pem().as_str(), &key.serialize_pem()),
        certificate.der().to_vec(),
    )
}

fn assert_acme_identifier(certificate_der: &[u8], digest: &[u8]) {
    let (_, certificate) = parse_x509_certificate(certificate_der).expect("parse challenge cert");
    let extension = certificate
        .extensions()
        .iter()
        .find(|extension| extension.oid.to_id_string() == "1.3.6.1.5.5.7.1.31")
        .expect("acmeIdentifier extension");
    assert!(extension.critical);
    assert_eq!(
        extension.value,
        [vec![0x04, 0x20], digest.to_vec()].concat()
    );
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
