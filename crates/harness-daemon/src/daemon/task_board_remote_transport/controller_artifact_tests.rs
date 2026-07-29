use base64::Engine as _;
use sha2::{Digest, Sha256};
use sqlx::{query, query_scalar};

use super::controller_authority_test_support::{
    HOST_ID, TOKEN_ENV, pinned_controller, spawn_barrier_server, spawn_probe_server,
    test_tls_material,
};
use super::controller_prepared_test_support::{
    PreparedLifecycle, completed_status, persist_claim, prepared_acceptance, status_request,
};
use super::wire::{
    RemoteArtifactEntry, RemoteArtifactFetchRequest, RemoteArtifactFetchResponse,
    RemoteArtifactManifest, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::daemon::db::AsyncDaemonDb;

const ARTIFACT_CONTENT: &[u8] = b"authenticated remote result bytes";
const STORED_AT: &str = "2026-07-19T10:00:50Z";

struct ArtifactFixture {
    state: PreparedLifecycle,
    request: RemoteArtifactFetchRequest,
    response: RemoteArtifactFetchResponse,
}

#[tokio::test]
async fn durable_artifact_replay_skips_a_second_http_fetch() {
    let fixture = completed_artifact_fixture("artifact-fetch-replay").await;
    let tls = test_tls_material();
    let server = spawn_barrier_server(
        &tls,
        serde_json::to_string(&fixture.response).expect("artifact response JSON"),
    )
    .await;
    let controller = pinned_controller(&server.endpoint, &tls);
    let db = fixture.state.prepared.db.clone();
    let request = fixture.request.clone();
    let first = temp_env::async_with_vars([(TOKEN_ENV, Some("artifact-secret"))], async {
        let call = tokio::spawn(async move { controller.fetch_artifact(&db, &request).await });
        server
            .seen
            .await
            .expect("artifact request reached executor");
        server.release.send(()).expect("release artifact response");
        call.await
            .expect("artifact controller task")
            .expect("atomically persist fetched artifact")
    })
    .await;
    assert_eq!(first.content, ARTIFACT_CONTENT);
    assert_eq!(server.requests.await.expect("artifact request count"), 1);

    let (endpoint, requests) = spawn_probe_server(&tls).await;
    let replay = pinned_controller(&endpoint, &tls)
        .fetch_artifact(&fixture.state.prepared.db, &fixture.request)
        .await
        .expect("durable artifact replay");
    assert_eq!(replay, first);
    assert_eq!(requests.await.expect("replay request count"), 0);
    assert_fetch_settled(&fixture.state.prepared.db, &fixture.request).await;
}

#[tokio::test]
async fn failed_http_fetch_retains_trust_authority_without_artifact() {
    let fixture = completed_artifact_fixture("artifact-fetch-crash").await;
    let tls = test_tls_material();
    let (endpoint, requests) = spawn_probe_server(&tls).await;
    let controller = pinned_controller(&endpoint, &tls);
    temp_env::async_with_vars([(TOKEN_ENV, Some("artifact-secret"))], async {
        controller
            .fetch_artifact(&fixture.state.prepared.db, &fixture.request)
            .await
            .expect_err("failed HTTP fetch must retain durable authority");
    })
    .await;
    assert_eq!(requests.await.expect("failed fetch request count"), 1);
    assert_fetch_pending(&fixture.state.prepared.db, &fixture.request).await;
}

#[tokio::test]
async fn artifact_response_cannot_cross_a_host_trust_rotation() {
    let fixture = completed_artifact_fixture("artifact-fetch-trust-rotation").await;
    let tls = test_tls_material();
    let server = spawn_barrier_server(
        &tls,
        serde_json::to_string(&fixture.response).expect("artifact response JSON"),
    )
    .await;
    let controller = pinned_controller(&server.endpoint, &tls);
    let db = fixture.state.prepared.db.clone();
    let request = fixture.request.clone();
    temp_env::async_with_vars([(TOKEN_ENV, Some("artifact-secret"))], async {
        let call = tokio::spawn(async move { controller.fetch_artifact(&db, &request).await });
        server
            .seen
            .await
            .expect("artifact request reached executor");
        rotate_host_trust(&fixture.state.prepared.db).await;
        server
            .release
            .send(())
            .expect("release stale artifact response");
        let error = call
            .await
            .expect("artifact controller task")
            .expect_err("rotated trust must reject artifact adoption");
        assert!(
            error
                .to_string()
                .contains("remote lifecycle transport trust changed from the frozen generation"),
            "{error}"
        );
    })
    .await;
    assert_eq!(server.requests.await.expect("stale fetch request count"), 1);
    assert_fetch_pending(&fixture.state.prepared.db, &fixture.request).await;
}

#[tokio::test]
async fn conflicting_immutable_artifact_preserves_fetch_authority() {
    let fixture = completed_artifact_fixture("artifact-fetch-conflict").await;
    insert_conflicting_artifact(&fixture).await;
    claim_fetch(&fixture).await;
    let error = fixture
        .state
        .prepared
        .db
        .record_task_board_remote_artifact_fetch_response(
            &fixture.request,
            &fixture.response,
            HOST_ID,
            STORED_AT,
        )
        .await
        .expect_err("immutable path conflict must fail closed");
    assert!(error.to_string().contains("immutable content evidence"));
    assert_fetch_authority(&fixture.state.prepared.db, &fixture.request).await;
    assert_eq!(
        artifact_count(&fixture.state.prepared.db, &fixture.request).await,
        1
    );
}

#[tokio::test]
async fn artifact_insert_failure_rolls_back_trust_consumption() {
    let fixture = completed_artifact_fixture("artifact-fetch-rollback").await;
    query(
        "CREATE TRIGGER reject_controller_artifact_insert
         BEFORE INSERT ON task_board_remote_artifacts
         BEGIN SELECT RAISE(ABORT, 'injected artifact insert failure'); END",
    )
    .execute(fixture.state.prepared.db.pool())
    .await
    .expect("install artifact failure trigger");
    claim_fetch(&fixture).await;
    fixture
        .state
        .prepared
        .db
        .record_task_board_remote_artifact_fetch_response(
            &fixture.request,
            &fixture.response,
            HOST_ID,
            STORED_AT,
        )
        .await
        .expect_err("artifact insert failure must roll back transaction");
    assert_fetch_pending(&fixture.state.prepared.db, &fixture.request).await;
}

async fn completed_artifact_fixture(item_id: &str) -> ArtifactFixture {
    let state = prepared_acceptance(item_id).await;
    persist_claim(&state).await;
    let entry = RemoteArtifactEntry {
        relative_path: "result/attempt.json".into(),
        sha256: hex::encode(Sha256::digest(ARTIFACT_CONTENT)),
        size_bytes: ARTIFACT_CONTENT.len() as u64,
        media_type: "application/vnd.harness.task-board-result+json".into(),
    };
    let status_request = status_request(&state);
    let mut status = completed_status(&state);
    status.output_artifacts = RemoteArtifactManifest {
        entries: vec![entry.clone()],
    };
    status.status_sha256.clear();
    let status = status.seal().expect("reseal completed artifact status");
    assert!(
        state
            .prepared
            .db
            .claim_task_board_remote_status_io_authority(&status_request, HOST_ID)
            .await
            .expect("claim status authority")
    );
    state
        .prepared
        .db
        .record_task_board_remote_assignment_status(&status_request, &status, HOST_ID)
        .await
        .expect("persist provisional completed status");
    let request = RemoteArtifactFetchRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.prepared.offer.binding.clone(),
        lease_id: "lease-admission".into(),
        offer_request_sha256: state.prepared.offer.request_sha256.clone(),
        relative_path: entry.relative_path.clone(),
        expected_sha256: entry.sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal artifact fetch request");
    let response = RemoteArtifactFetchResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.offer_request_sha256.clone(),
        artifact: entry,
        content_base64: base64::engine::general_purpose::STANDARD.encode(ARTIFACT_CONTENT),
    };
    ArtifactFixture {
        state,
        request,
        response,
    }
}

async fn claim_fetch(fixture: &ArtifactFixture) {
    let trust = fixture
        .state
        .prepared
        .db
        .task_board_remote_operation_trust_fence(HOST_ID)
        .await
        .expect("load artifact host trust");
    assert!(
        fixture
            .state
            .prepared
            .db
            .claim_task_board_remote_artifact_fetch_io_authority_fenced(
                &fixture.request,
                HOST_ID,
                &trust,
            )
            .await
            .expect("claim artifact fetch authority")
    );
}

async fn assert_fetch_pending(db: &AsyncDaemonDb, request: &RemoteArtifactFetchRequest) {
    assert_fetch_authority(db, request).await;
    assert_eq!(artifact_count(db, request).await, 0);
}

async fn assert_fetch_settled(db: &AsyncDaemonDb, request: &RemoteArtifactFetchRequest) {
    let assignment = db
        .task_board_remote_assignment(&request.binding.assignment_id)
        .await
        .expect("load settled artifact assignment")
        .expect("settled artifact assignment exists");
    assert!(assignment.controller_operation.is_none());
    assert_eq!(artifact_count(db, request).await, 1);
}

async fn assert_fetch_authority(db: &AsyncDaemonDb, request: &RemoteArtifactFetchRequest) {
    let assignment = db
        .task_board_remote_assignment(&request.binding.assignment_id)
        .await
        .expect("load pending artifact assignment")
        .expect("pending artifact assignment exists");
    let operation = assignment
        .controller_operation
        .expect("artifact fetch authority remains durable");
    assert_eq!(operation.kind, "fetch_artifact");
    assert_eq!(operation.request_sha256, request.request_sha256);
}

async fn artifact_count(db: &AsyncDaemonDb, request: &RemoteArtifactFetchRequest) -> i64 {
    query_scalar(
        "SELECT COUNT(*) FROM task_board_remote_artifacts
         WHERE assignment_id = ?1 AND fencing_epoch = ?2 AND relative_path = ?3",
    )
    .bind(&request.binding.assignment_id)
    .bind(i64::try_from(request.binding.fencing_epoch).expect("fencing epoch"))
    .bind(&request.relative_path)
    .fetch_one(db.pool())
    .await
    .expect("count controller artifacts")
}

async fn insert_conflicting_artifact(fixture: &ArtifactFixture) {
    let conflicting = b"different immutable bytes";
    query(
        "INSERT INTO task_board_remote_artifacts (
           assignment_id, fencing_epoch, lease_id, offer_request_sha256,
           authenticated_principal, relative_path, sha256, size_bytes, media_type,
           content, stored_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
    )
    .bind(&fixture.request.binding.assignment_id)
    .bind(i64::try_from(fixture.request.binding.fencing_epoch).expect("fencing epoch"))
    .bind(&fixture.request.lease_id)
    .bind(&fixture.request.offer_request_sha256)
    .bind(HOST_ID)
    .bind(&fixture.request.relative_path)
    .bind(hex::encode(Sha256::digest(conflicting)))
    .bind(i64::try_from(conflicting.len()).expect("artifact size"))
    .bind("application/vnd.harness.task-board-result+json")
    .bind(conflicting.as_ref())
    .bind(STORED_AT)
    .execute(fixture.state.prepared.db.pool())
    .await
    .expect("insert conflicting immutable artifact");
}

async fn rotate_host_trust(db: &AsyncDaemonDb) {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load host settings");
    let host = settings
        .execution_hosts
        .first_mut()
        .expect("configured remote host");
    host.endpoint = "https://rotated-executor.example.test".into();
    host.certificate_fingerprint = crate::task_board::remote_spki_pin::encode([0xbb; 32]);
    host.credential_reference = "env://HARNESS_ROTATED_REMOTE_TOKEN".into();
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("rotate host trust");
}
