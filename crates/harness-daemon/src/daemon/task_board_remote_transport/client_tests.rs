use std::collections::BTreeSet;
use std::sync::Arc;

use rcgen::{BasicConstraints, CertificateParams, IsCa, Issuer, KeyPair};
use rustls::ServerConfig;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;

use super::client::{
    RemoteExecutionHttpClient, RemoteExecutionHttpClientConfig, RemoteExecutionHttpError,
};
use super::tls_pin::RemoteTlsPinError;
use super::wire::{RemoteHostAdvertisement, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION};
use crate::daemon::remote_acme::RemoteCertificateBundle;
use crate::task_board::remote_spki_pin;
use crate::task_board::{TaskBoardExecutionHostConfig, validate_execution_host_config};

#[tokio::test]
async fn pairing_spki_pin_bootstraps_authenticated_controller_tls() {
    let tls = test_tls_material();
    let body = serde_json::to_string(&advertisement()).expect("advertisement JSON");
    let (endpoint, request) = spawn_https_server(&tls, response(200, &body, &[])).await;
    let paired_host = TaskBoardExecutionHostConfig {
        host_id: "executor-1".into(),
        endpoint: endpoint.trim_end_matches('/').into(),
        certificate_fingerprint: tls.spki_pin.clone(),
        credential_reference: "env://HARNESS_REMOTE_TLS_TEST_TOKEN".into(),
        enabled: true,
    };
    validate_execution_host_config(&paired_host).expect("pairing output is valid host trust");
    let config = RemoteExecutionHttpClientConfig::new(
        &paired_host.endpoint,
        &paired_host.certificate_fingerprint,
        &paired_host.credential_reference,
        &paired_host.host_id,
    )
    .expect("client config");
    let client = RemoteExecutionHttpClient::new_with_roots(config, vec![tls.ca_der.clone()])
        .expect("pinned client");

    temp_env::async_with_vars(
        [("HARNESS_REMOTE_TLS_TEST_TOKEN", Some("executor-secret"))],
        async {
            client.advertise().await.expect("authenticated advertise");
        },
    )
    .await;
    let request = request.await.expect("server task").expect("HTTP request");
    assert!(request.contains("authorization: Bearer executor-secret\r\n"));
    assert!(request.contains("x-harness-remote-client-id: executor-1\r\n"));
}

#[tokio::test]
async fn wrong_spki_pin_fails_before_authorization_reaches_server() {
    let tls = test_tls_material();
    let (endpoint, request) = spawn_https_server(&tls, response(200, "{}", &[])).await;
    let config = RemoteExecutionHttpClientConfig::new(
        &endpoint,
        &remote_spki_pin::encode([0; 32]),
        "env://HARNESS_REMOTE_WRONG_PIN_TOKEN",
        "executor-1",
    )
    .expect("client config");
    let client = RemoteExecutionHttpClient::new_with_roots(config, vec![tls.ca_der.clone()])
        .expect("pinned client");

    let error = temp_env::async_with_vars(
        [("HARNESS_REMOTE_WRONG_PIN_TOKEN", Some("must-not-leak"))],
        async { client.advertise().await.expect_err("wrong pin denied") },
    )
    .await;
    assert_eq!(error, RemoteExecutionHttpError::Transport);
    assert_eq!(request.await.expect("server task"), None);
    assert!(!error.to_string().contains("must-not-leak"));
}

#[tokio::test]
async fn redirects_are_not_followed_and_errors_redact_credentials() {
    let tls = test_tls_material();
    let headers = [("Location", "https://redirect.invalid/steal")];
    let (endpoint, request) = spawn_https_server(&tls, response(302, "", &headers)).await;
    let config = RemoteExecutionHttpClientConfig::new(
        &endpoint,
        &tls.spki_pin,
        "env://HARNESS_REMOTE_REDIRECT_TOKEN",
        "executor-1",
    )
    .expect("client config");
    assert!(!format!("{config:?}").contains("HARNESS_REMOTE_REDIRECT_TOKEN"));
    let client = RemoteExecutionHttpClient::new_with_roots(config, vec![tls.ca_der.clone()])
        .expect("pinned client");
    let error = temp_env::async_with_vars(
        [("HARNESS_REMOTE_REDIRECT_TOKEN", Some("redirect-secret"))],
        async { client.advertise().await.expect_err("redirect denied") },
    )
    .await;

    assert_eq!(
        error,
        RemoteExecutionHttpError::HttpStatus {
            status: 302,
            code: None,
            message: None,
        }
    );
    assert!(!format!("{error:?}").contains("redirect-secret"));
    assert!(request.await.expect("server task").is_some());
}

#[test]
fn configured_spki_pin_requires_canonical_pairing_form() {
    let tls = test_tls_material();
    for invalid in [
        String::new(),
        "a".repeat(64),
        tls.spki_pin.to_uppercase(),
        tls.spki_pin.trim_end_matches('=').to_owned(),
        tls.spki_pin.replacen('/', ":", 1),
    ] {
        let config = RemoteExecutionHttpClientConfig::new(
            "https://localhost:8443/",
            &invalid,
            "env://HARNESS_REMOTE_PIN_TEST_TOKEN",
            "executor-1",
        )
        .expect("structural client config");
        assert_eq!(
            RemoteExecutionHttpClient::new_with_roots(config, vec![tls.ca_der.clone()])
                .expect_err("noncanonical pin denied"),
            RemoteExecutionHttpError::Tls(RemoteTlsPinError::InvalidPin)
        );
    }
}

#[tokio::test]
async fn renewed_leaf_with_the_same_spki_remains_pinned() {
    let (initial, renewed) = renewed_tls_materials();
    assert_ne!(initial.leaf_der, renewed.leaf_der);
    assert_eq!(initial.spki_pin, renewed.spki_pin);
    let body = serde_json::to_string(&advertisement()).expect("advertisement JSON");
    let (endpoint, request) = spawn_https_server(&renewed, response(200, &body, &[])).await;
    let config = RemoteExecutionHttpClientConfig::new(
        &endpoint,
        &initial.spki_pin,
        "env://HARNESS_REMOTE_RENEWED_TLS_TEST_TOKEN",
        "executor-1",
    )
    .expect("client config");
    let client = RemoteExecutionHttpClient::new_with_roots(config, vec![renewed.ca_der.clone()])
        .expect("SPKI-pinned client");

    temp_env::async_with_vars(
        [(
            "HARNESS_REMOTE_RENEWED_TLS_TEST_TOKEN",
            Some("executor-secret"),
        )],
        async {
            client
                .advertise()
                .await
                .expect("renewed certificate with the paired SPKI");
        },
    )
    .await;
    assert!(request.await.expect("server task").is_some());
}

#[test]
fn complete_private_client_contract_is_reachable_for_coordinator_integration() {
    let _ = RemoteExecutionHttpClient::new;
    let _ = RemoteExecutionHttpClient::advertise;
    let _ = RemoteExecutionHttpClient::offer;
    let _ = RemoteExecutionHttpClient::upload_source_bundle;
    let _ = RemoteExecutionHttpClient::claim;
    let _ = RemoteExecutionHttpClient::renew_lease;
    let _ = RemoteExecutionHttpClient::status;
    let _ = RemoteExecutionHttpClient::cancel;
    let _ = RemoteExecutionHttpClient::settle;
    let _ = RemoteExecutionHttpClient::fetch_artifact;
}

struct TestTlsMaterial {
    server: Arc<ServerConfig>,
    ca_der: CertificateDer<'static>,
    leaf_der: CertificateDer<'static>,
    spki_pin: String,
}

fn test_tls_material() -> TestTlsMaterial {
    let ca_key = KeyPair::generate().expect("CA key");
    let mut ca_params = CertificateParams::default();
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let ca = ca_params.self_signed(&ca_key).expect("CA certificate");
    let issuer = Issuer::from_params(&ca_params, &ca_key);
    let leaf_key = KeyPair::generate().expect("leaf key");
    let leaf = leaf_params(1)
        .expect("leaf params")
        .signed_by(&leaf_key, &issuer)
        .expect("leaf certificate");
    test_tls_material_from_leaf(&ca, &leaf_key, leaf)
}

fn renewed_tls_materials() -> (TestTlsMaterial, TestTlsMaterial) {
    let ca_key = KeyPair::generate().expect("CA key");
    let mut ca_params = CertificateParams::default();
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let ca = ca_params.self_signed(&ca_key).expect("CA certificate");
    let issuer = Issuer::from_params(&ca_params, &ca_key);
    let leaf_key = KeyPair::generate().expect("leaf key");
    let initial = leaf_params(1)
        .expect("initial leaf params")
        .signed_by(&leaf_key, &issuer)
        .expect("initial leaf certificate");
    let renewed = leaf_params(2)
        .expect("renewed leaf params")
        .signed_by(&leaf_key, &issuer)
        .expect("renewed leaf certificate");
    (
        test_tls_material_from_leaf(&ca, &leaf_key, initial),
        test_tls_material_from_leaf(&ca, &leaf_key, renewed),
    )
}

fn leaf_params(serial: u64) -> Result<CertificateParams, rcgen::Error> {
    let mut params = CertificateParams::new(["localhost".to_string()])?;
    params.serial_number = Some(serial.into());
    Ok(params)
}

fn test_tls_material_from_leaf(
    ca: &rcgen::Certificate,
    leaf_key: &KeyPair,
    leaf: rcgen::Certificate,
) -> TestTlsMaterial {
    let leaf_der = CertificateDer::from(leaf.der().to_vec());
    let ca_der = CertificateDer::from(ca.der().to_vec());
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(leaf_key.serialize_der()));
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let server = ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("TLS versions")
        .with_no_client_auth()
        .with_single_cert(vec![leaf_der.clone(), ca_der.clone()], key)
        .expect("server TLS config");
    let bundle =
        RemoteCertificateBundle::new_for_tests(leaf.pem().as_str(), &leaf_key.serialize_pem());
    TestTlsMaterial {
        server: Arc::new(server),
        ca_der,
        leaf_der,
        spki_pin: bundle.spki_sha256_pin().expect("pairing SPKI pin"),
    }
}

async fn spawn_https_server(
    tls: &TestTlsMaterial,
    response: String,
) -> (String, tokio::task::JoinHandle<Option<String>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind TLS");
    let address = listener.local_addr().expect("TLS address");
    let acceptor = TlsAcceptor::from(Arc::clone(&tls.server));
    let task = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept TCP");
        let Ok(mut stream) = acceptor.accept(stream).await else {
            return None;
        };
        let mut bytes = Vec::new();
        let mut chunk = [0_u8; 2048];
        loop {
            let read = stream.read(&mut chunk).await.expect("read HTTP");
            if read == 0 {
                return None;
            }
            bytes.extend_from_slice(&chunk[..read]);
            if bytes.windows(4).any(|window| window == b"\r\n\r\n") {
                break;
            }
        }
        stream
            .write_all(response.as_bytes())
            .await
            .expect("write HTTP");
        stream.shutdown().await.expect("shutdown HTTP");
        Some(String::from_utf8(bytes).expect("HTTP request UTF-8"))
    });
    (format!("https://localhost:{}/", address.port()), task)
}

fn response(status: u16, body: &str, headers: &[(&str, &str)]) -> String {
    let reason = if status == 200 { "OK" } else { "Found" };
    let mut response = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n",
        body.len()
    );
    for (name, value) in headers {
        response.push_str(&format!("{name}: {value}\r\n"));
    }
    response.push_str("\r\n");
    response.push_str(body);
    response
}

fn advertisement() -> RemoteHostAdvertisement {
    RemoteHostAdvertisement {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        host_id: "host-1".into(),
        host_instance_id: "instance-1".into(),
        protocol_version: 1,
        capabilities: BTreeSet::from(["implementation_write".into()]),
        runtimes: BTreeSet::from(["codex".into()]),
        repositories: BTreeSet::from(["org/repo".into()]),
        capacity: 2,
        active_assignments: 0,
        sent_at: "2026-07-19T12:00:00Z".into(),
    }
}
