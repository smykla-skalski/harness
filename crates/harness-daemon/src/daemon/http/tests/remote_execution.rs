use chrono::{Duration, SecondsFormat, Utc};
use reqwest::{Client, Response, StatusCode};
use serde::Serialize;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use crate::daemon::http::{DaemonHttpAuthMode, DaemonHttpState};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_auth::REMOTE_CLIENT_ID_HEADER;
use crate::daemon::remote_identity::RemoteClientRegistration;
use crate::daemon::task_board_remote_transport::routes::{
    ADVERTISE_PATH, ARTIFACT_PATH, CANCEL_PATH, CLAIM_PATH, LEASE_RENEW_PATH, OFFER_PATH,
    SETTLED_PATH, SOURCE_BUNDLE_PATH, STATUS_PATH,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactFetchRequest, RemoteArtifactManifest, RemoteAssignmentWireState,
    RemoteAttemptBinding, RemoteCancelRequest, RemoteCancelResponse, RemoteClaimRequest,
    RemoteClaimResponse, RemoteHostAdvertisement, RemoteLeaseRenewRequest,
    RemoteLeaseRenewResponse, RemoteOfferDisposition, RemoteOfferRequest, RemoteOfferResponse,
    RemoteSettledRequest, RemoteSettledResponse, RemoteSourceBundleUploadRequest,
    RemoteSourceBundleUploadResponse, RemoteSourceMaterial, RemoteStatusRequest,
    RemoteStatusResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION, test_codex_launch,
};
use crate::task_board::{
    TaskBoardExecutionPhase, TaskBoardLocalExecutionHostConfig,
    TaskBoardLocalExecutionRepositoryConfig, TaskBoardPhaseCapabilityProfile,
    TaskBoardWorkflowKind,
};

use super::test_http_state_with_db;

const HOST_ID: &str = "executor-a";
const OTHER_EXECUTOR: &str = "executor-b";
const OPERATOR: &str = "operator";
const HOST_INSTANCE: &str = "instance-a";
const REPOSITORY: &str = "example/harness";

#[path = "remote_execution_cleanup.rs"]
mod cleanup;
#[path = "remote_execution_source_bundle.rs"]
mod source_bundle;

#[tokio::test]
async fn private_executor_routes_require_exact_execution_identity() {
    let state = remote_executor_state().await;
    let (base_url, server) = serve(state).await;
    let client = Client::new();

    let missing = client
        .get(format!("{base_url}{ADVERTISE_PATH}"))
        .send()
        .await
        .expect("missing-auth advertise");
    assert_eq!(missing.status(), StatusCode::UNAUTHORIZED);

    let operator = authenticated_get(&client, &base_url, OPERATOR).await;
    assert_eq!(operator.status(), StatusCode::FORBIDDEN);

    let wrong_executor = authenticated_get(&client, &base_url, OTHER_EXECUTOR).await;
    assert_eq!(wrong_executor.status(), StatusCode::FORBIDDEN);

    let accepted = authenticated_get(&client, &base_url, HOST_ID).await;
    assert_eq!(accepted.status(), StatusCode::OK);
    let advertisement = accepted
        .json::<RemoteHostAdvertisement>()
        .await
        .expect("decode advertisement");
    assert_eq!(advertisement.host_id, HOST_ID);
    assert_eq!(advertisement.host_instance_id, HOST_INSTANCE);
    assert_eq!(advertisement.active_assignments, 0);
    advertisement.validate().expect("valid advertisement");

    let removed_heartbeat = client
        .post(format!("{base_url}/v1/task-board-execution/heartbeat"))
        .send()
        .await
        .expect("removed heartbeat route");
    assert_eq!(removed_heartbeat.status(), StatusCode::NOT_FOUND);

    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn executor_offer_replay_and_digest_tamper_are_fail_closed() {
    let state = remote_executor_state().await;
    let async_db = state.async_db.get().expect("async db").clone();
    let (base_url, server) = serve(state).await;
    let client = Client::new();
    let offer = offer_request("assignment-route-offer", "offer-key");

    let denied = authenticated_post(&client, &base_url, OFFER_PATH, OPERATOR, &offer).await;
    assert_eq!(denied.status(), StatusCode::FORBIDDEN);

    let first = authenticated_post(&client, &base_url, OFFER_PATH, HOST_ID, &offer).await;
    assert_eq!(first.status(), StatusCode::OK);
    let first = first
        .json::<RemoteOfferResponse>()
        .await
        .expect("decode accepted offer");
    first.validate(&offer).expect("validate accepted offer");
    assert_eq!(first.disposition, RemoteOfferDisposition::Accepted);

    let replay = authenticated_post(&client, &base_url, OFFER_PATH, HOST_ID, &offer).await;
    assert_eq!(replay.status(), StatusCode::OK);
    let replay = replay
        .json::<RemoteOfferResponse>()
        .await
        .expect("decode replayed offer");
    assert_eq!(replay, first);

    let mut tampered = offer_request("assignment-route-tampered", "tampered-key");
    tampered.launch.prompt.push_str(" altered");
    let rejected = authenticated_post(&client, &base_url, OFFER_PATH, HOST_ID, &tampered).await;
    assert_eq!(rejected.status(), StatusCode::BAD_REQUEST);
    assert!(
        async_db
            .task_board_remote_assignment("assignment-route-tampered")
            .await
            .expect("load tampered assignment")
            .is_none()
    );

    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn executor_offer_replays_durable_acceptance_and_rejection_after_settings_disable() {
    let state = remote_executor_state().await;
    let db = state.async_db.get().expect("async db").clone();
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings");
    settings.local_execution_host.capacity = 1;
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("limit executor capacity");
    let (base_url, server) = serve(state).await;
    let client = Client::new();
    let accepted_request = offer_request("assignment-route-accepted-replay", "accepted-key");
    let mut rejected_request = offer_request("assignment-route-rejected-replay", "rejected-key");
    rejected_request.binding.execution_id = "execution-route-rejected".into();
    rejected_request.binding.action_key = "review:capacity-rejected".into();
    // The launch's workflow execution id and action must track the rebound binding.
    rejected_request.launch = test_codex_launch(
        TaskBoardExecutionPhase::Review,
        "execution-route-rejected",
        "review:capacity-rejected",
        "Review the exact frozen revision",
    );
    rejected_request.request_sha256.clear();
    let rejected_request = rejected_request
        .seal()
        .expect("reseal independent rejected offer");

    let accepted = authenticated_post(&client, &base_url, OFFER_PATH, HOST_ID, &accepted_request)
        .await
        .json::<RemoteOfferResponse>()
        .await
        .expect("decode accepted offer");
    assert_eq!(accepted.disposition, RemoteOfferDisposition::Accepted);
    let rejected =
        authenticated_post(&client, &base_url, OFFER_PATH, HOST_ID, &rejected_request).await;
    let rejected_status = rejected.status();
    let rejected_body = rejected.text().await.expect("read rejection response");
    assert_eq!(rejected_status, StatusCode::OK, "{rejected_body}");
    let rejected = serde_json::from_str::<RemoteOfferResponse>(&rejected_body)
        .expect("decode durable rejection");
    assert_eq!(rejected.disposition, RemoteOfferDisposition::Rejected);
    assert_eq!(
        rejected.rejection_code.as_deref(),
        Some("executor_unavailable")
    );

    settings.local_execution_host.enabled = false;
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("disable executor after lost responses");
    let accepted_replay =
        authenticated_post(&client, &base_url, OFFER_PATH, HOST_ID, &accepted_request)
            .await
            .json::<RemoteOfferResponse>()
            .await
            .expect("decode accepted replay");
    assert_eq!(accepted_replay, accepted);
    let rejected_replay =
        authenticated_post(&client, &base_url, OFFER_PATH, HOST_ID, &rejected_request)
            .await
            .json::<RemoteOfferResponse>()
            .await
            .expect("decode rejected replay");
    assert_eq!(rejected_replay, rejected);

    let mut conflicting = rejected_request.clone();
    conflicting.launch.prompt.push_str(" conflicting");
    conflicting.request_sha256.clear();
    let conflicting = conflicting.seal().expect("reseal conflicting offer");
    let conflict = authenticated_post(&client, &base_url, OFFER_PATH, HOST_ID, &conflicting).await;
    assert_eq!(conflict.status(), StatusCode::CONFLICT);

    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn executor_lifecycle_replays_renewal_without_accepting_old_generation() {
    let state = remote_executor_state().await;
    let (base_url, server) = serve(state).await;
    let client = Client::new();
    let offer = offer_request("assignment-route-lifecycle", "lifecycle-key");
    let accepted = authenticated_post(&client, &base_url, OFFER_PATH, HOST_ID, &offer)
        .await
        .json::<RemoteOfferResponse>()
        .await
        .expect("decode offer response");
    let original_acceptance = accepted.clone();
    let old_lease = accepted.lease.expect("accepted lease");

    let claim = RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: old_lease.lease_id.clone(),
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal claim");
    let claimed = authenticated_post(&client, &base_url, CLAIM_PATH, HOST_ID, &claim).await;
    assert_eq!(claimed.status(), StatusCode::OK);
    let claimed = claimed
        .json::<RemoteClaimResponse>()
        .await
        .expect("decode claim");
    claimed.validate(&claim).expect("validate claim response");
    assert_offer_replay(&client, &base_url, &offer, &original_acceptance).await;

    let renew = RemoteLeaseRenewRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: old_lease.lease_id.clone(),
        offer_request_sha256: offer.request_sha256.clone(),
        extend_seconds: 120,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal renewal");
    let renewed = authenticated_post(&client, &base_url, LEASE_RENEW_PATH, HOST_ID, &renew)
        .await
        .json::<RemoteLeaseRenewResponse>()
        .await
        .expect("decode renewal");
    renewed.validate(&renew).expect("validate renewal response");
    assert_ne!(renewed.lease.lease_id, old_lease.lease_id);

    let replay = authenticated_post(&client, &base_url, LEASE_RENEW_PATH, HOST_ID, &renew)
        .await
        .json::<RemoteLeaseRenewResponse>()
        .await
        .expect("decode renewal replay");
    assert_eq!(replay, renewed);
    assert_offer_replay(&client, &base_url, &offer, &original_acceptance).await;

    let stale_status = status_request(&offer, &old_lease.lease_id);
    let stale = authenticated_post(&client, &base_url, STATUS_PATH, HOST_ID, &stale_status).await;
    assert_eq!(stale.status(), StatusCode::CONFLICT);

    let current_status = status_request(&offer, &renewed.lease.lease_id);
    let current =
        authenticated_post(&client, &base_url, STATUS_PATH, HOST_ID, &current_status).await;
    assert_eq!(current.status(), StatusCode::OK);
    let current = current
        .json::<RemoteStatusResponse>()
        .await
        .expect("decode status");
    current
        .validate(&current_status)
        .expect("validate exact status generation");
    assert_eq!(current.state, RemoteAssignmentWireState::Claimed);

    exercise_cancel_settle_and_artifact_failure(
        &client,
        &base_url,
        &offer,
        &renewed.lease.lease_id,
    )
    .await;
    assert_offer_replay(&client, &base_url, &offer, &original_acceptance).await;

    server.abort();
    let _ = server.await;
}

async fn assert_offer_replay(
    client: &Client,
    base_url: &str,
    offer: &RemoteOfferRequest,
    expected: &RemoteOfferResponse,
) {
    let replay = authenticated_post(client, base_url, OFFER_PATH, HOST_ID, offer)
        .await
        .json::<RemoteOfferResponse>()
        .await
        .expect("decode immutable offer replay");
    assert_eq!(&replay, expected);
}

async fn exercise_cancel_settle_and_artifact_failure(
    client: &Client,
    base_url: &str,
    offer: &RemoteOfferRequest,
    lease_id: &str,
) {
    let cancel = RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id.to_owned(),
        offer_request_sha256: offer.request_sha256.clone(),
        reason: "controller cancelled".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cancel");
    let cancelled = authenticated_post(client, base_url, CANCEL_PATH, HOST_ID, &cancel)
        .await
        .json::<RemoteCancelResponse>()
        .await
        .expect("decode cancellation");
    cancelled.validate(&cancel).expect("validate cancellation");
    assert_eq!(cancelled.state, RemoteAssignmentWireState::Cancelled);

    let settled = RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id.to_owned(),
        offer_request_sha256: offer.request_sha256.clone(),
        terminal_state: RemoteAssignmentWireState::Cancelled,
        result_sha256: None,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal settlement");
    let settled_bytes = authenticated_post(client, base_url, SETTLED_PATH, HOST_ID, &settled)
        .await
        .bytes()
        .await
        .expect("read settlement response");
    let settled_response =
        serde_json::from_slice::<RemoteSettledResponse>(&settled_bytes).expect("decode settlement");
    settled_response
        .validate(&settled)
        .expect("validate settlement");
    let replay_bytes = authenticated_post(client, base_url, SETTLED_PATH, HOST_ID, &settled)
        .await
        .bytes()
        .await
        .expect("read settlement replay");
    assert_eq!(replay_bytes, settled_bytes);

    let artifact = RemoteArtifactFetchRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id.to_owned(),
        offer_request_sha256: offer.request_sha256.clone(),
        relative_path: "result/report.json".into(),
        expected_sha256: "e".repeat(64),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal artifact request");
    let unavailable = authenticated_post(client, base_url, ARTIFACT_PATH, HOST_ID, &artifact).await;
    assert_eq!(unavailable.status(), StatusCode::CONFLICT);
}

async fn remote_executor_state() -> DaemonHttpState {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    state.daemon_epoch = HOST_INSTANCE.into();
    register_client(&state, HOST_ID, RemoteRole::ExecutionCoordinator);
    register_client(&state, OTHER_EXECUTOR, RemoteRole::ExecutionCoordinator);
    register_client(&state, OPERATOR, RemoteRole::Operator);
    let db = state.async_db.get().expect("async db");
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load settings");
    settings.local_execution_host = TaskBoardLocalExecutionHostConfig {
        enabled: true,
        host_id: HOST_ID.into(),
        capacity: 2,
        repositories: vec![TaskBoardLocalExecutionRepositoryConfig {
            repository: REPOSITORY.into(),
            checkout_path: "/tmp/harness-remote-route-test".into(),
        }],
        runtimes: vec!["codex".into()],
        capabilities: vec![TaskBoardPhaseCapabilityProfile::ReviewReadOnly],
    };
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure local executor");
    state
}

fn register_client(state: &DaemonHttpState, client_id: &str, role: RemoteRole) {
    let registration = RemoteClientRegistration::new_for_tests(
        client_id,
        "Remote Executor Route Test",
        "test",
        role,
        &[] as &[RemoteAccessScope],
        &token(client_id),
        "2026-07-19T08:00:00Z",
    )
    .expect("registration");
    state
        .db
        .get()
        .expect("sync db")
        .lock()
        .expect("db lock")
        .register_remote_client(&registration)
        .expect("register client");
}

fn offer_request(assignment_id: &str, idempotency_key: &str) -> RemoteOfferRequest {
    RemoteOfferRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: RemoteAttemptBinding {
            assignment_id: assignment_id.into(),
            execution_id: "execution-route-test".into(),
            phase: TaskBoardExecutionPhase::Review,
            workflow_kind: TaskBoardWorkflowKind::Review,
            action_key: "review:codex".into(),
            attempt: 1,
            idempotency_key: idempotency_key.into(),
            host_id: HOST_ID.into(),
            host_instance_id: HOST_INSTANCE.into(),
            fencing_epoch: 1,
            configuration_revision: 1,
            execution_record_sha256: "a".repeat(64),
            repository: REPOSITORY.into(),
            base_revision: "1111111111111111111111111111111111111111".into(),
            expected_head_revision: Some("1111111111111111111111111111111111111111".into()),
        },
        lease_seconds: 60,
        deadline_at: (Utc::now() + Duration::minutes(10))
            .to_rfc3339_opts(SecondsFormat::AutoSi, true),
        launch: test_codex_launch(
            TaskBoardExecutionPhase::Review,
            "execution-route-test",
            "review:codex",
            "Review the exact frozen revision",
        ),
        source: RemoteSourceMaterial::repository_revision(
            REPOSITORY,
            "1111111111111111111111111111111111111111",
        ),
        artifacts: RemoteArtifactManifest::default(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal offer")
}

fn status_request(offer: &RemoteOfferRequest, lease_id: &str) -> RemoteStatusRequest {
    RemoteStatusRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id.to_owned(),
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal status")
}

async fn authenticated_get(client: &Client, base_url: &str, client_id: &str) -> Response {
    client
        .get(format!("{base_url}{ADVERTISE_PATH}"))
        .header(REMOTE_CLIENT_ID_HEADER, client_id)
        .bearer_auth(token(client_id))
        .send()
        .await
        .expect("send authenticated advertise")
}

async fn authenticated_post<T: Serialize>(
    client: &Client,
    base_url: &str,
    path: &str,
    client_id: &str,
    body: &T,
) -> Response {
    client
        .post(format!("{base_url}{path}"))
        .header(REMOTE_CLIENT_ID_HEADER, client_id)
        .bearer_auth(token(client_id))
        .json(body)
        .send()
        .await
        .expect("send authenticated remote executor request")
}

fn token(client_id: &str) -> String {
    format!("remote-executor-route-token-{client_id}-abcdefghijklmnopqrstuvwxyz")
}

async fn serve(state: DaemonHttpState) -> (String, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind route test listener");
    let address = listener.local_addr().expect("route test address");
    let app = super::super::daemon_http_router(state);
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.expect("serve route test");
    });
    (format!("http://{address}"), server)
}
