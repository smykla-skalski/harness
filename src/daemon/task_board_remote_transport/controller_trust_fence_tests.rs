use super::controller_authority_test_support::{
    HOST_ID, TOKEN_ENV, accepted_offer, central_offer, pinned_controller,
    pinned_controller_with_retained_trust, pinned_controller_with_times, spawn_barrier_server,
    spawn_probe_server, test_tls_material,
};
use super::controller_prepared_test_support::{
    claim_request, claim_response, completed_status, persist_claim, prepared_acceptance,
    renewal_request, renewal_response, status_request,
};
use super::controller_settlement_tests::{settlement, settlement_ready_controller};
use super::controller_tests::{cancel_request, cancel_response};
use super::wire::{RemoteHeartbeatRequest, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION};
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::TaskBoardRemoteAssignmentState;

#[tokio::test]
async fn offer_response_cannot_cross_a_host_trust_rotation() {
    let state = central_offer().await;
    let response = accepted_offer(&state);
    let tls = test_tls_material();
    let server = spawn_barrier_server(
        &tls,
        serde_json::to_string(&response).expect("offer response JSON"),
    )
    .await;
    let controller = pinned_controller(&server.endpoint, &tls);
    let db = state.fixture.db.clone();
    let request = state.fixture.request.clone();

    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let call = tokio::spawn(async move { controller.offer(&db, &request).await });
        server.seen.await.expect("offer reached executor");
        rotate_host_trust(&state.fixture.db).await;
        server
            .release
            .send(())
            .expect("release stale offer response");
        let error = call
            .await
            .expect("offer task")
            .expect_err("rotated trust must reject offer adoption");
        assert!(error.to_string().contains("remote operation host"));
    })
    .await;
    assert_eq!(server.requests.await.expect("offer request count"), 1);
    let assignment = state
        .fixture
        .db
        .task_board_remote_assignment(&state.fixture.request.binding.assignment_id)
        .await
        .expect("load rotated offer")
        .expect("rotated offer exists");
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Offered);
    assert!(assignment.lease_id.is_none());
    assert_eq!(
        assignment
            .controller_operation
            .as_ref()
            .map(|token| token.kind.as_str()),
        Some("offer")
    );
}

#[tokio::test]
async fn status_evidence_cannot_cross_a_host_trust_rotation() {
    let state = prepared_acceptance("status-trust-rotation").await;
    persist_claim(&state).await;
    let request = status_request(&state);
    let response = completed_status(&state);
    let tls = test_tls_material();
    let server = spawn_barrier_server(
        &tls,
        serde_json::to_string(&response).expect("status response JSON"),
    )
    .await;
    let controller = pinned_controller(&server.endpoint, &tls);
    let db = state.prepared.db.clone();

    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let call = tokio::spawn(async move { controller.status(&db, &request).await });
        server.seen.await.expect("status reached executor");
        rotate_host_trust(&state.prepared.db).await;
        server
            .release
            .send(())
            .expect("release stale status response");
        let error = call
            .await
            .expect("status task")
            .expect_err("rotated trust must reject status adoption");
        assert!(
            error
                .to_string()
                .contains("remote lifecycle transport trust changed from the frozen generation"),
            "{error}"
        );
    })
    .await;
    assert_eq!(server.requests.await.expect("status request count"), 1);
    let assignment = state
        .prepared
        .db
        .task_board_remote_assignment(&state.prepared.offer.binding.assignment_id)
        .await
        .expect("load rotated status")
        .expect("rotated status exists");
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Claimed);
    assert!(assignment.status_response.is_none());
    assert_eq!(
        assignment
            .controller_operation
            .as_ref()
            .map(|token| token.kind.as_str()),
        Some("status")
    );
}

#[tokio::test]
async fn claim_response_cannot_cross_a_host_trust_rotation() {
    let state = prepared_acceptance("claim-trust-rotation").await;
    let request = claim_request(&state);
    let response = claim_response(&state);
    let tls = test_tls_material();
    let server = spawn_barrier_server(
        &tls,
        serde_json::to_string(&response).expect("claim response JSON"),
    )
    .await;
    let controller = pinned_controller_with_times(
        &server.endpoint,
        &tls,
        [
            state.times.before_expiry.clone(),
            state.times.before_expiry.clone(),
        ],
    );
    let db = state.prepared.db.clone();

    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let call = tokio::spawn(async move { controller.claim(&db, &request).await });
        server.seen.await.expect("claim reached executor");
        rotate_host_trust(&state.prepared.db).await;
        server
            .release
            .send(())
            .expect("release stale claim response");
        let error = call
            .await
            .expect("claim task")
            .expect_err("rotated trust must reject claim adoption");
        assert!(error.to_string().contains("remote operation host"));
    })
    .await;
    assert_eq!(server.requests.await.expect("claim request count"), 1);
    let assignment = load_assignment(
        &state.prepared.db,
        &state.prepared.offer.binding.assignment_id,
    )
    .await;
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Offered);
    assert!(assignment.claim_receipt.is_none());
    assert_operation(&assignment, "claim");
}

#[tokio::test]
async fn renewal_response_cannot_cross_a_host_trust_rotation() {
    let state = prepared_acceptance("renew-trust-rotation").await;
    persist_claim(&state).await;
    let request = renewal_request(&state);
    let response = renewal_response(&state);
    let tls = test_tls_material();
    let server = spawn_barrier_server(
        &tls,
        serde_json::to_string(&response).expect("renewal response JSON"),
    )
    .await;
    let controller = pinned_controller_with_times(
        &server.endpoint,
        &tls,
        [
            state.times.before_expiry.clone(),
            state.times.before_expiry.clone(),
        ],
    );
    let db = state.prepared.db.clone();

    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let call = tokio::spawn(async move { controller.renew_lease(&db, &request).await });
        server.seen.await.expect("renewal reached executor");
        rotate_host_trust(&state.prepared.db).await;
        server
            .release
            .send(())
            .expect("release stale renewal response");
        let error = call
            .await
            .expect("renewal task")
            .expect_err("rotated trust must reject renewal adoption");
        assert!(error.to_string().contains("remote operation host"));
    })
    .await;
    assert_eq!(server.requests.await.expect("renewal request count"), 1);
    let assignment = load_assignment(
        &state.prepared.db,
        &state.prepared.offer.binding.assignment_id,
    )
    .await;
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Claimed);
    assert_eq!(assignment.lease_id.as_deref(), Some("lease-admission"));
    assert_operation(&assignment, "renew");
}

#[tokio::test]
async fn cancel_response_cannot_cross_a_host_trust_rotation() {
    let state = prepared_acceptance("cancel-trust-rotation").await;
    let request = cancel_request(&state.prepared.offer, "lease-admission");
    let response = cancel_response(&state.prepared.offer, &state.times.before_expiry);
    let tls = test_tls_material();
    let server = spawn_barrier_server(
        &tls,
        serde_json::to_string(&response).expect("cancel response JSON"),
    )
    .await;
    let controller = pinned_controller_with_times(
        &server.endpoint,
        &tls,
        [
            state.times.before_expiry.clone(),
            state.times.before_expiry.clone(),
        ],
    );
    let db = state.prepared.db.clone();

    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let call = tokio::spawn(async move { controller.cancel(&db, &request).await });
        server.seen.await.expect("cancel reached executor");
        rotate_host_trust(&state.prepared.db).await;
        server
            .release
            .send(())
            .expect("release stale cancel response");
        let error = call
            .await
            .expect("cancel task")
            .expect_err("rotated trust must reject cancel adoption");
        assert!(
            error
                .to_string()
                .contains("remote lifecycle transport trust changed from the frozen generation"),
            "{error}"
        );
    })
    .await;
    assert_eq!(server.requests.await.expect("cancel request count"), 1);
    let assignment = load_assignment(
        &state.prepared.db,
        &state.prepared.offer.binding.assignment_id,
    )
    .await;
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Offered);
    assert_eq!(
        assignment.cancel_requested_at.as_deref(),
        Some(state.times.before_expiry.as_str())
    );
    assert_eq!(
        assignment.error.as_deref(),
        Some("controller requested cancellation")
    );
    assert_operation(&assignment, "cancel");
}

#[tokio::test]
async fn settlement_response_cannot_cross_a_host_trust_rotation() {
    let state = settlement_ready_controller("settlement-trust-rotation").await;
    let (request, response) = settlement(&state).await;
    let tls = test_tls_material();
    let server = spawn_barrier_server(
        &tls,
        serde_json::to_string(&response).expect("settlement response JSON"),
    )
    .await;
    let controller =
        pinned_controller_with_times(&server.endpoint, &tls, [state.times.after_expiry.clone()]);
    let db = state.prepared.db.clone();

    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let call = tokio::spawn(async move { controller.settle(&db, &request).await });
        server.seen.await.expect("settlement reached executor");
        rotate_host_trust(&state.prepared.db).await;
        server
            .release
            .send(())
            .expect("release stale settlement response");
        let error = call
            .await
            .expect("settlement task")
            .expect_err("rotated trust must reject settlement adoption");
        assert!(
            error
                .to_string()
                .contains("remote lifecycle transport trust changed from the frozen generation"),
            "{error}"
        );
    })
    .await;
    assert_eq!(server.requests.await.expect("settlement request count"), 1);
    let assignment = load_assignment(
        &state.prepared.db,
        &state.prepared.offer.binding.assignment_id,
    )
    .await;
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Unknown);
    assert_operation(&assignment, "settle");
    assert!(
        state
            .prepared
            .db
            .task_board_remote_settlement_receipt(&state.prepared.offer.binding.assignment_id)
            .await
            .expect("load settlement receipt")
            .is_none()
    );
}

#[tokio::test]
async fn disabled_host_rejects_heartbeat_before_io() {
    let fixture = crate::daemon::db::remote_controller_fixture(1).await;
    let trust = fixture
        .db
        .task_board_remote_host_trust_fence(HOST_ID)
        .await
        .expect("load retained heartbeat trust");
    let tls = test_tls_material();
    let (endpoint, requests) = spawn_probe_server(&tls).await;
    let controller = pinned_controller_with_retained_trust(&endpoint, &tls, trust);
    disable_host(&fixture.db).await;
    let request = RemoteHeartbeatRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        host_id: HOST_ID.into(),
        host_instance_id: "instance-a".into(),
        active_assignments: 0,
        sent_at: crate::daemon::db::utc_now(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal heartbeat");

    let error = controller
        .heartbeat(&fixture.db, &request)
        .await
        .expect_err("disabled host must reject heartbeat before I/O");
    assert!(error.to_string().contains("disabled"));
    assert_eq!(requests.await.expect("heartbeat request count"), 0);
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

async fn disable_host(db: &AsyncDaemonDb) {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load host settings");
    settings
        .execution_hosts
        .first_mut()
        .expect("configured remote host")
        .enabled = false;
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("disable host");
}

async fn load_assignment(
    db: &AsyncDaemonDb,
    assignment_id: &str,
) -> crate::daemon::db::TaskBoardRemoteAssignmentRecord {
    db.task_board_remote_assignment(assignment_id)
        .await
        .expect("load trust-fenced assignment")
        .expect("trust-fenced assignment exists")
}

fn assert_operation(assignment: &crate::daemon::db::TaskBoardRemoteAssignmentRecord, kind: &str) {
    assert_eq!(
        assignment
            .controller_operation
            .as_ref()
            .map(|operation| operation.kind.as_str()),
        Some(kind)
    );
}
