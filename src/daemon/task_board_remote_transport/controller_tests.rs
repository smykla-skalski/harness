use std::sync::Arc;

use chrono::{Duration, SecondsFormat, Utc};
use rcgen::{BasicConstraints, CertificateParams, IsCa, Issuer, KeyPair};
use rustls::ServerConfig;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;

use super::client::{
    RemoteExecutionHttpClient, RemoteExecutionHttpClientConfig, RemoteExecutionHttpError,
};
use super::controller::{
    RemoteExecutionControllerClient, lifecycle_response_may_be_lost, renewal_response_may_be_lost,
};
use super::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteCancelResponse, RemoteClaimRequest,
    RemoteClaimResponse, RemoteLease, RemoteLeaseRenewRequest, RemoteLeaseRenewResponse,
    RemoteOfferDisposition, RemoteOfferResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::daemon::db::{
    RemoteControllerFixture, TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome,
    remote_controller_fixture,
};
use crate::task_board::{
    TASK_BOARD_REMOTE_PROTOCOL_VERSION, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionHostAdvertisement, TaskBoardPhaseCapabilityProfile,
    TaskBoardRemoteAssignmentState, TaskBoardWorkflowExecutionCas,
};

pub(super) const HOST_ID: &str = "executor-a";
pub(super) const TOKEN_ENV: &str = "HARNESS_REMOTE_CONTROLLER_TEST_TOKEN";

#[test]
fn controller_transport_api_has_production_entrypoints() {
    let _ = RemoteExecutionControllerClient::connect;
    let _ = RemoteExecutionControllerClient::refresh_observation;
    let _ = RemoteExecutionControllerClient::heartbeat;
    let _ = RemoteExecutionControllerClient::offer;
    let _ = RemoteExecutionControllerClient::claim;
    let _ = RemoteExecutionControllerClient::renew_lease;
    let _ = RemoteExecutionControllerClient::status;
    let _ = RemoteExecutionControllerClient::cancel;
    let _ = RemoteExecutionControllerClient::settle;
    let _ = RemoteExecutionControllerClient::fetch_artifact;
}

#[test]
fn only_ambiguous_renewal_failures_replay_the_exact_request() {
    assert!(renewal_response_may_be_lost(
        &RemoteExecutionHttpError::Transport
    ));
    assert!(renewal_response_may_be_lost(
        &RemoteExecutionHttpError::Decode
    ));
    assert!(renewal_response_may_be_lost(
        &RemoteExecutionHttpError::HttpStatus {
            status: 503,
            code: None,
            message: None,
        }
    ));
    assert!(!renewal_response_may_be_lost(
        &RemoteExecutionHttpError::Credential(
            super::credentials::RemoteExecutionCredentialError::UnsupportedReference,
        )
    ));
    assert!(!renewal_response_may_be_lost(
        &RemoteExecutionHttpError::HttpStatus {
            status: 409,
            code: None,
            message: None,
        }
    ));
    assert!(lifecycle_response_may_be_lost(
        &RemoteExecutionHttpError::Transport
    ));
}

#[tokio::test]
async fn claim_and_lost_renewal_response_converge_through_durable_controller_cas() {
    let (fixture, times) = prepared_controller_fixture().await;

    let claim_request = claim_request(&fixture.request, "lease-l1");
    let claim_response = claim_response(&fixture.request, &times.initial_expiry, &times.offered_at);
    let renewal_request = renewal_request(&fixture.request, "lease-l1");
    let renewal_response = renewal_response(&fixture.request, &times.renewed_expiry);
    let tls = test_tls_material();
    let script = vec![
        ScriptedResponse::Json(serde_json::to_string(&claim_response).expect("claim JSON")),
        ScriptedResponse::Drop,
        ScriptedResponse::Json(serde_json::to_string(&renewal_response).expect("renewal JSON")),
    ];
    let (endpoint, requests) = spawn_scripted_https_server(&tls, script).await;
    let client = pinned_client(&endpoint, &tls);
    let controller = RemoteExecutionControllerClient::new_for_tests(HOST_ID, client);

    let (claim, renewal) =
        temp_env::async_with_vars([(TOKEN_ENV, Some("controller-secret"))], async {
            let claimed = controller
                .claim(&fixture.db, &claim_request)
                .await
                .expect("claim response is durably recorded");
            let renewed = controller
                .renew_lease(&fixture.db, &renewal_request)
                .await
                .expect("exact renewal replay converges");
            (claimed, renewed)
        })
        .await;
    assert_eq!(claim.0, claim_response);
    assert!(matches!(
        claim.1,
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Claimed
    ));
    assert_eq!(renewal.0, renewal_response);
    assert!(matches!(
        renewal.1,
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Claimed
                && record.lease_id.as_deref() == Some("lease-l2")
    ));
    let requests = requests.await.expect("scripted TLS server");
    assert_eq!(requests.len(), 3);
    assert_eq!(request_body(&requests[1]), request_body(&requests[2]));
    assert_eq!(
        serde_json::from_slice::<RemoteLeaseRenewRequest>(request_body(&requests[1]))
            .expect("renewal request JSON"),
        renewal_request,
    );
    let durable = fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect("load controller assignment")
        .expect("controller assignment exists");
    assert_eq!(durable.state, TaskBoardRemoteAssignmentState::Claimed);
    assert_eq!(durable.lease_id.as_deref(), Some("lease-l2"));
    assert_eq!(
        durable.lease_expires_at.as_deref(),
        Some(times.renewed_expiry.as_str())
    );
}

pub(super) struct ControllerTimes {
    pub(super) offered_at: String,
    pub(super) initial_expiry: String,
    pub(super) renewed_expiry: String,
}

pub(super) async fn prepared_controller_fixture() -> (RemoteControllerFixture, ControllerTimes) {
    let mut fixture = remote_controller_fixture(1).await;
    let now = Utc::now();
    let times = ControllerTimes {
        offered_at: canonical_time(now),
        initial_expiry: canonical_time(now + Duration::minutes(10)),
        renewed_expiry: canonical_time(now + Duration::minutes(20)),
    };
    fixture.request.lease_seconds = 600;
    fixture.request.deadline_at = canonical_time(now + Duration::hours(1));
    fixture.request = fixture
        .request
        .clone()
        .seal()
        .expect("reseal current offer");
    fixture
        .db
        .record_task_board_execution_host_observation(
            &TaskBoardExecutionHostAdvertisement {
                host_id: HOST_ID.into(),
                host_instance_id: "instance-a".into(),
                protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
                repositories: vec!["example/harness".into()],
                runtimes: vec!["codex".into()],
                capabilities: vec![TaskBoardPhaseCapabilityProfile::ReviewReadOnly],
                capacity: 1,
                active_assignments: 0,
                heartbeat_at: times.offered_at.clone(),
            },
            &times.offered_at,
        )
        .await
        .expect("refresh host observation");
    let offered = fixture
        .db
        .offer_task_board_remote_assignment(
            &TaskBoardWorkflowExecutionCas::from(&fixture.execution),
            &TaskBoardExecutionAttemptCas::from(&fixture.attempt),
            &fixture.request,
            HOST_ID,
            &times.offered_at,
            &times.initial_expiry,
            &fixture.request.deadline_at,
        )
        .await
        .expect("persist offer before remote I/O");
    assert!(matches!(offered, TaskBoardRemoteOfferOutcome::Created(_)));
    assert!(
        fixture
            .db
            .claim_task_board_remote_offer_io_authority(
                &fixture.request,
                HOST_ID,
                &crate::daemon::db::utc_now(),
            )
            .await
            .expect("claim offer I/O authority")
            .is_some()
    );
    fixture
        .db
        .record_task_board_remote_offer_response(
            &accepted_offer(&fixture.request, &times.initial_expiry),
            HOST_ID,
            &times.offered_at,
        )
        .await
        .expect("persist accepted offer");
    (fixture, times)
}

fn accepted_offer(
    request: &super::wire::RemoteOfferRequest,
    expires_at: &str,
) -> RemoteOfferResponse {
    RemoteOfferResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.request_sha256.clone(),
        disposition: RemoteOfferDisposition::Accepted,
        lease: Some(RemoteLease {
            lease_id: "lease-l1".into(),
            expires_at: expires_at.into(),
        }),
        rejection_code: None,
    }
}

fn claim_request(request: &super::wire::RemoteOfferRequest, lease_id: &str) -> RemoteClaimRequest {
    RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        lease_id: lease_id.into(),
        offer_request_sha256: request.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal claim")
}

fn claim_response(
    request: &super::wire::RemoteOfferRequest,
    expires_at: &str,
    claimed_at: &str,
) -> RemoteClaimResponse {
    RemoteClaimResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.request_sha256.clone(),
        lease: RemoteLease {
            lease_id: "lease-l1".into(),
            expires_at: expires_at.into(),
        },
        claimed_at: claimed_at.into(),
    }
}

fn renewal_request(
    request: &super::wire::RemoteOfferRequest,
    lease_id: &str,
) -> RemoteLeaseRenewRequest {
    RemoteLeaseRenewRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        lease_id: lease_id.into(),
        offer_request_sha256: request.request_sha256.clone(),
        extend_seconds: 600,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal renewal")
}

fn renewal_response(
    request: &super::wire::RemoteOfferRequest,
    expires_at: &str,
) -> RemoteLeaseRenewResponse {
    RemoteLeaseRenewResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.request_sha256.clone(),
        lease: RemoteLease {
            lease_id: "lease-l2".into(),
            expires_at: expires_at.into(),
        },
    }
}

pub(super) fn cancel_request(
    request: &super::wire::RemoteOfferRequest,
    lease_id: &str,
) -> RemoteCancelRequest {
    RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        lease_id: lease_id.into(),
        offer_request_sha256: request.request_sha256.clone(),
        reason: "controller requested cancellation".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cancel")
}

pub(super) fn cancel_response(
    request: &super::wire::RemoteOfferRequest,
    observed_at: &str,
) -> RemoteCancelResponse {
    RemoteCancelResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.request_sha256.clone(),
        cancel_response_sha256: String::new(),
        state: RemoteAssignmentWireState::Cancelled,
        claimed_at: None,
        started_at: None,
        workspace_ref: None,
        observed_at: observed_at.into(),
    }
    .seal(&cancel_request(request, "lease-admission"))
    .expect("seal cancel response")
}

// Cancelling a claimed assignment must echo the observed claim evidence.
pub(super) fn claimed_cancel_response(
    request: &super::wire::RemoteOfferRequest,
    observed_at: &str,
    claimed_at: &str,
) -> RemoteCancelResponse {
    RemoteCancelResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.request_sha256.clone(),
        cancel_response_sha256: String::new(),
        state: RemoteAssignmentWireState::Cancelled,
        claimed_at: Some(claimed_at.into()),
        started_at: None,
        workspace_ref: None,
        observed_at: observed_at.into(),
    }
    .seal(&cancel_request(request, "lease-admission"))
    .expect("seal claimed cancel response")
}

fn canonical_time(time: chrono::DateTime<Utc>) -> String {
    time.to_rfc3339_opts(SecondsFormat::Secs, true)
}

pub(super) struct TestTlsMaterial {
    server: Arc<ServerConfig>,
    ca_der: CertificateDer<'static>,
    spki_pin: String,
}

pub(super) enum ScriptedResponse {
    Json(String),
    Drop,
}

pub(super) fn test_tls_material() -> TestTlsMaterial {
    let ca_key = KeyPair::generate().expect("CA key");
    let mut ca_params = CertificateParams::default();
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let ca = ca_params.self_signed(&ca_key).expect("CA certificate");
    let issuer = Issuer::from_params(&ca_params, &ca_key);
    let leaf_key = KeyPair::generate().expect("leaf key");
    let leaf = CertificateParams::new(["localhost".to_string()])
        .expect("leaf params")
        .signed_by(&leaf_key, &issuer)
        .expect("leaf certificate");
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
    TestTlsMaterial {
        server: Arc::new(server),
        ca_der,
        spki_pin: crate::task_board::remote_spki_pin::encode(
            crate::daemon::remote_certificate_identity::spki_sha256_digest_from_der(
                leaf_der.as_ref(),
            )
            .expect("test certificate SPKI"),
        ),
    }
}

pub(super) fn pinned_client(endpoint: &str, tls: &TestTlsMaterial) -> RemoteExecutionHttpClient {
    let config = RemoteExecutionHttpClientConfig::new(
        endpoint,
        &tls.spki_pin,
        &format!("env://{TOKEN_ENV}"),
        HOST_ID,
    )
    .expect("client config");
    RemoteExecutionHttpClient::new_with_roots(config, vec![tls.ca_der.clone()])
        .expect("pinned client")
}

pub(super) async fn spawn_scripted_https_server(
    tls: &TestTlsMaterial,
    script: Vec<ScriptedResponse>,
) -> (String, tokio::task::JoinHandle<Vec<Vec<u8>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind TLS");
    let address = listener.local_addr().expect("TLS address");
    let acceptor = TlsAcceptor::from(Arc::clone(&tls.server));
    let task = tokio::spawn(async move {
        let mut requests = Vec::with_capacity(script.len());
        for response in script {
            // Bound each accept: a client that never connects (e.g. settle
            // failing before any HTTP request) must surface as a fast assertion
            // on the collected request count, never a whole-suite hang.
            let Ok(accepted) =
                tokio::time::timeout(std::time::Duration::from_secs(10), listener.accept()).await
            else {
                break;
            };
            let (stream, _) = accepted.expect("accept TCP");
            let mut stream = acceptor.accept(stream).await.expect("accept TLS");
            requests.push(read_request(&mut stream).await);
            if let ScriptedResponse::Json(body) = response {
                stream
                    .write_all(http_response(&body).as_bytes())
                    .await
                    .expect("write HTTP");
            }
            stream.shutdown().await.expect("shutdown HTTP");
        }
        requests
    });
    (format!("https://localhost:{}/", address.port()), task)
}

async fn read_request(
    stream: &mut tokio_rustls::server::TlsStream<tokio::net::TcpStream>,
) -> Vec<u8> {
    let mut bytes = Vec::new();
    let mut chunk = [0_u8; 2048];
    let (header_end, content_length) = loop {
        let read = stream.read(&mut chunk).await.expect("read HTTP headers");
        assert_ne!(read, 0, "HTTP request ended before headers");
        bytes.extend_from_slice(&chunk[..read]);
        if let Some(index) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            let header_end = index + 4;
            let headers = String::from_utf8_lossy(&bytes[..header_end]);
            let content_length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().expect("content length"))
                })
                .unwrap_or(0);
            break (header_end, content_length);
        }
    };
    while bytes.len() < header_end + content_length {
        let read = stream.read(&mut chunk).await.expect("read HTTP body");
        assert_ne!(read, 0, "HTTP request ended before body");
        bytes.extend_from_slice(&chunk[..read]);
    }
    bytes
}

pub(super) fn request_body(request: &[u8]) -> &[u8] {
    let header_end = request
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .expect("HTTP headers")
        + 4;
    &request[header_end..]
}

fn http_response(body: &str) -> String {
    format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}
