use std::sync::Arc;
use std::time::Duration as StdDuration;

use chrono::{DateTime, Duration, SecondsFormat, Utc};
use rcgen::{BasicConstraints, CertificateParams, IsCa, Issuer, KeyPair};
use rustls::ServerConfig;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio_rustls::TlsAcceptor;

use super::client::{RemoteExecutionHttpClient, RemoteExecutionHttpClientConfig};
use super::controller::RemoteExecutionControllerClient;
use super::wire::{
    RemoteClaimRequest, RemoteClaimResponse, RemoteLease, RemoteOfferDisposition,
    RemoteOfferResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::daemon::db::{
    RemoteControllerFixture, TaskBoardRemoteHostTrustFence, TaskBoardRemoteOfferOutcome,
    remote_controller_fixture,
};
use crate::errors::CliError;
use crate::task_board::{
    TASK_BOARD_REMOTE_PROTOCOL_VERSION, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionHostAdvertisement, TaskBoardExecutionHostConfig,
    TaskBoardPhaseCapabilityProfile, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord,
};

pub(super) const HOST_ID: &str = "executor-a";
pub(super) const TOKEN_ENV: &str = "HARNESS_REMOTE_AUTHORITY_TEST_TOKEN";

pub(super) struct AuthorityFixture {
    pub(super) fixture: RemoteControllerFixture,
    pub(super) offered_at: String,
    pub(super) initial_expiry: String,
}

pub(super) async fn central_offer() -> AuthorityFixture {
    central_offer_at(Utc::now(), 600, Utc::now() + Duration::hours(1)).await
}

pub(super) async fn expired_central_offer() -> AuthorityFixture {
    let now = Utc::now();
    central_offer_at(now - Duration::minutes(2), 60, now + Duration::minutes(10)).await
}

async fn central_offer_at(
    offered: DateTime<Utc>,
    lease_seconds: u32,
    deadline: DateTime<Utc>,
) -> AuthorityFixture {
    let mut fixture = remote_controller_fixture(1).await;
    let offered_at = canonical_time(offered);
    let initial_expiry = canonical_time(offered + Duration::seconds(i64::from(lease_seconds)));
    fixture.request.lease_seconds = lease_seconds;
    fixture.request.deadline_at = canonical_time(deadline);
    fixture.request = fixture
        .request
        .clone()
        .seal()
        .expect("reseal authority offer");
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
                heartbeat_at: offered_at.clone(),
            },
            &offered_at,
        )
        .await
        .expect("refresh authority host observation");
    let outcome = fixture
        .db
        .offer_task_board_remote_assignment(
            &TaskBoardWorkflowExecutionCas::from(&fixture.execution),
            &TaskBoardExecutionAttemptCas::from(&fixture.attempt),
            &fixture.request,
            HOST_ID,
            &offered_at,
            &initial_expiry,
            &fixture.request.deadline_at,
        )
        .await
        .expect("persist central authority offer");
    assert!(matches!(outcome, TaskBoardRemoteOfferOutcome::Created(_)));
    AuthorityFixture {
        fixture,
        offered_at,
        initial_expiry,
    }
}

pub(super) async fn persist_acceptance(state: &AuthorityFixture) {
    assert!(
        state
            .fixture
            .db
            .claim_task_board_remote_offer_io_authority(
                &state.fixture.request,
                HOST_ID,
                &state.offered_at,
            )
            .await
            .expect("claim offer authority")
            .is_some()
    );
    state
        .fixture
        .db
        .record_task_board_remote_offer_response(&accepted_offer(state), HOST_ID, &state.offered_at)
        .await
        .expect("persist accepted offer");
}

pub(super) fn accepted_offer(state: &AuthorityFixture) -> RemoteOfferResponse {
    RemoteOfferResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.fixture.request.binding.clone(),
        offer_request_sha256: state.fixture.request.request_sha256.clone(),
        disposition: RemoteOfferDisposition::Accepted,
        lease: Some(RemoteLease {
            lease_id: "lease-l1".into(),
            expires_at: state.initial_expiry.clone(),
        }),
        rejection_code: None,
    }
}

pub(super) fn claim_request(state: &AuthorityFixture) -> RemoteClaimRequest {
    RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.fixture.request.binding.clone(),
        lease_id: "lease-l1".into(),
        offer_request_sha256: state.fixture.request.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal authority claim")
}

pub(super) fn claim_response(state: &AuthorityFixture) -> RemoteClaimResponse {
    RemoteClaimResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.fixture.request.binding.clone(),
        offer_request_sha256: state.fixture.request.request_sha256.clone(),
        lease: RemoteLease {
            lease_id: "lease-l1".into(),
            expires_at: state.initial_expiry.clone(),
        },
        claimed_at: canonical_time(Utc::now()),
    }
}

pub(super) async fn try_stop(state: &AuthorityFixture, reason: &str) -> Result<(), CliError> {
    let stop = prepare_stop(state, reason).await?;
    apply_stop(state, &stop).await
}

pub(super) struct StopCas {
    expected: TaskBoardWorkflowExecutionCas,
    updated: TaskBoardWorkflowExecutionRecord,
}

pub(super) async fn prepare_stop(
    state: &AuthorityFixture,
    reason: &str,
) -> Result<StopCas, CliError> {
    let current = state
        .fixture
        .db
        .task_board_workflow_execution(&state.fixture.execution.execution_id)
        .await?
        .expect("execution exists");
    let mut stopped = current.clone();
    stopped.transition.execution_state = crate::task_board::TaskBoardExecutionState::HumanRequired;
    stopped.blocked_reason = Some(reason.into());
    stopped.updated_at = canonical_time(Utc::now());
    Ok(StopCas {
        expected: TaskBoardWorkflowExecutionCas::from(&current),
        updated: stopped,
    })
}

pub(super) async fn apply_stop(state: &AuthorityFixture, stop: &StopCas) -> Result<(), CliError> {
    state
        .fixture
        .db
        .compare_and_set_task_board_workflow_execution(&stop.expected, &stop.updated)
        .await
        .map(|_| ())
}

pub(crate) struct TestTlsMaterial {
    server: Arc<ServerConfig>,
    ca_der: CertificateDer<'static>,
    spki_pin: String,
}

impl TestTlsMaterial {
    pub(crate) fn server_config(&self) -> Arc<ServerConfig> {
        Arc::clone(&self.server)
    }

    pub(crate) fn ca_der(&self) -> CertificateDer<'static> {
        self.ca_der.clone()
    }

    pub(crate) fn spki_pin(&self) -> &str {
        &self.spki_pin
    }
}

pub(crate) fn test_tls_material() -> TestTlsMaterial {
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

pub(super) fn pinned_controller(
    endpoint: &str,
    tls: &TestTlsMaterial,
) -> RemoteExecutionControllerClient {
    pinned_controller_for_host(endpoint, tls, HOST_ID)
}

pub(super) fn pinned_controller_for_host(
    endpoint: &str,
    tls: &TestTlsMaterial,
    host_id: &str,
) -> RemoteExecutionControllerClient {
    RemoteExecutionControllerClient::new_for_tests(host_id, pinned_client(endpoint, tls, host_id))
}

pub(super) fn pinned_controller_with_times(
    endpoint: &str,
    tls: &TestTlsMaterial,
    times: impl IntoIterator<Item = String>,
) -> RemoteExecutionControllerClient {
    RemoteExecutionControllerClient::new_for_tests_with_times(
        HOST_ID,
        pinned_client(endpoint, tls, HOST_ID),
        times,
    )
}

pub(super) fn pinned_controller_with_retained_trust(
    endpoint: &str,
    tls: &TestTlsMaterial,
    trust: TaskBoardRemoteHostTrustFence,
) -> RemoteExecutionControllerClient {
    RemoteExecutionControllerClient::new_for_tests_with_retained_trust(
        HOST_ID,
        pinned_client(endpoint, tls, HOST_ID),
        trust,
    )
}

pub(crate) fn remote_host_config(
    endpoint: &str,
    tls: &TestTlsMaterial,
    credential_reference: &str,
    enabled: bool,
) -> TaskBoardExecutionHostConfig {
    TaskBoardExecutionHostConfig {
        host_id: HOST_ID.into(),
        endpoint: endpoint.trim_end_matches('/').into(),
        certificate_fingerprint: tls.spki_pin.clone(),
        credential_reference: credential_reference.into(),
        enabled,
    }
}

pub(super) fn pinned_controller_for_trust_with_times(
    trust: TaskBoardRemoteHostTrustFence,
    tls: &TestTlsMaterial,
    times: impl IntoIterator<Item = String>,
) -> RemoteExecutionControllerClient {
    let host_id = trust.config.host_id.clone();
    let config = {
        let host = &trust.config;
        RemoteExecutionHttpClientConfig::new(
            &host.endpoint,
            &host.certificate_fingerprint,
            &host.credential_reference,
            &host.host_id,
        )
        .expect("authority client config")
    };
    let client = RemoteExecutionHttpClient::new_with_roots(config, vec![tls.ca_der.clone()])
        .expect("authority pinned client");
    RemoteExecutionControllerClient::new_for_tests_with_retained_trust_and_times(
        &host_id, client, trust, times,
    )
}

fn pinned_client(
    endpoint: &str,
    tls: &TestTlsMaterial,
    host_id: &str,
) -> RemoteExecutionHttpClient {
    let config = RemoteExecutionHttpClientConfig::new(
        endpoint,
        &tls.spki_pin,
        &format!("env://{TOKEN_ENV}"),
        host_id,
    )
    .expect("authority client config");
    RemoteExecutionHttpClient::new_with_roots(config, vec![tls.ca_der.clone()])
        .expect("authority pinned client")
}

pub(super) struct BarrierServer {
    pub(super) endpoint: String,
    pub(super) seen: oneshot::Receiver<()>,
    pub(super) release: oneshot::Sender<()>,
    pub(super) requests: tokio::task::JoinHandle<usize>,
}

pub(super) async fn spawn_barrier_server(tls: &TestTlsMaterial, body: String) -> BarrierServer {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind TLS");
    let address = listener.local_addr().expect("TLS address");
    let acceptor = TlsAcceptor::from(Arc::clone(&tls.server));
    let (seen_tx, seen) = oneshot::channel();
    let (release, release_rx) = oneshot::channel();
    let requests = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept TCP");
        let mut stream = acceptor.accept(stream).await.expect("accept TLS");
        read_request(&mut stream).await;
        let _ = seen_tx.send(());
        let _ = release_rx.await;
        write_response(&mut stream, 200, &body).await;
        let Ok(Ok((stream, _))) =
            tokio::time::timeout(StdDuration::from_millis(250), listener.accept()).await
        else {
            return 1;
        };
        let mut stream = acceptor.accept(stream).await.expect("accept replay TLS");
        read_request(&mut stream).await;
        write_response(&mut stream, 500, "{}").await;
        2
    });
    BarrierServer {
        endpoint: format!("https://localhost:{}/", address.port()),
        seen,
        release,
        requests,
    }
}

pub(super) async fn spawn_probe_server(
    tls: &TestTlsMaterial,
) -> (String, tokio::task::JoinHandle<usize>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind TLS");
    let address = listener.local_addr().expect("TLS address");
    let acceptor = TlsAcceptor::from(Arc::clone(&tls.server));
    let task = tokio::spawn(async move {
        let Ok(Ok((stream, _))) =
            tokio::time::timeout(StdDuration::from_millis(250), listener.accept()).await
        else {
            return 0;
        };
        let mut stream = acceptor.accept(stream).await.expect("accept TLS");
        read_request(&mut stream).await;
        write_response(&mut stream, 500, "{}").await;
        1
    });
    (format!("https://localhost:{}/", address.port()), task)
}

async fn read_request(stream: &mut tokio_rustls::server::TlsStream<tokio::net::TcpStream>) {
    let mut bytes = Vec::new();
    let mut chunk = [0_u8; 2048];
    loop {
        let read = stream.read(&mut chunk).await.expect("read HTTP request");
        assert_ne!(read, 0, "HTTP request ended early");
        bytes.extend_from_slice(&chunk[..read]);
        let Some(index) = bytes.windows(4).position(|window| window == b"\r\n\r\n") else {
            continue;
        };
        let header_end = index + 4;
        let headers = String::from_utf8_lossy(&bytes[..header_end]);
        let length = headers
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().expect("content length"))
            })
            .unwrap_or(0);
        if bytes.len() >= header_end + length {
            return;
        }
    }
}

async fn write_response(
    stream: &mut tokio_rustls::server::TlsStream<tokio::net::TcpStream>,
    status: u16,
    body: &str,
) {
    let response = format!(
        "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(response.as_bytes())
        .await
        .expect("write HTTP");
    stream.shutdown().await.expect("shutdown HTTP");
}

fn canonical_time(time: DateTime<Utc>) -> String {
    time.to_rfc3339_opts(SecondsFormat::Secs, true)
}
