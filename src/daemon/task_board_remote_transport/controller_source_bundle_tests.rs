use sha2::{Digest as _, Sha256};
use std::sync::Arc;

use super::controller_authority_test_support::{
    BarrierServer, HOST_ID, TOKEN_ENV, pinned_controller, pinned_controller_for_host,
    spawn_barrier_server, test_tls_material,
};
use super::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteSourceBundleUploadRequest,
    RemoteSourceBundleUploadResponse, RemoteSourceMaterial,
};
use crate::daemon::db::{REMOTE_EXECUTOR_CLAIMED_AT, remote_controller_fixture};
use crate::task_board::TaskBoardWorkflowKind;

const BASE: &str = "1111111111111111111111111111111111111111";
const RESULT: &str = "2222222222222222222222222222222222222222";
const LEASE_EXPIRES: &str = "2026-07-19T10:01:00Z";
const DEADLINE: &str = "2026-07-19T10:10:00Z";

#[tokio::test]
async fn controller_upload_replays_immutable_receipt_without_a_second_request() {
    let fixture = remote_controller_fixture(1).await;
    let (offer, content) = bundle_offer(&fixture.request);
    fixture
        .db
        .insert_task_board_remote_source_bundle_offer_for_test(
            &offer,
            HOST_ID,
            REMOTE_EXECUTOR_CLAIMED_AT,
            LEASE_EXPIRES,
            DEADLINE,
        )
        .await
        .expect("insert controller source offer");
    let request = RemoteSourceBundleUploadRequest::seal(offer, &content)
        .expect("seal controller source upload");
    let response =
        RemoteSourceBundleUploadResponse::seal(&request, REMOTE_EXECUTOR_CLAIMED_AT.into())
            .expect("seal executor upload response");
    let tls = test_tls_material();
    let BarrierServer {
        endpoint,
        seen,
        release,
        requests,
    } = spawn_barrier_server(
        &tls,
        serde_json::to_string(&response).expect("source upload response JSON"),
    )
    .await;
    let controller = Arc::new(pinned_controller(&endpoint, &tls));
    let (first, replay) =
        temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
            let pending_controller = Arc::clone(&controller);
            let pending_db = fixture.db.clone();
            let pending_request = request.clone();
            let pending = tokio::spawn(async move {
                pending_controller
                    .upload_source_bundle(&pending_db, &pending_request)
                    .await
            });
            seen.await.expect("source upload reached executor");
            release.send(()).expect("release source upload response");
            let first = pending
                .await
                .expect("source upload controller task")
                .expect("persist source upload receipt");
            let replay = controller
                .upload_source_bundle(&fixture.db, &request)
                .await
                .expect("replay source upload receipt");
            (first, replay)
        })
        .await;
    assert_eq!(
        serde_json::to_vec(&first).expect("first response JSON"),
        serde_json::to_vec(&replay).expect("replay response JSON")
    );
    assert_eq!(first, response);
    assert_eq!(requests.await.expect("source upload server"), 1);
}

#[tokio::test]
async fn controller_upload_replay_rejects_wrong_principal_and_digest_without_network() {
    let fixture = remote_controller_fixture(1).await;
    let (offer, content) = bundle_offer(&fixture.request);
    fixture
        .db
        .insert_task_board_remote_source_bundle_offer_for_test(
            &offer,
            HOST_ID,
            REMOTE_EXECUTOR_CLAIMED_AT,
            LEASE_EXPIRES,
            DEADLINE,
        )
        .await
        .expect("insert controller source offer");
    let request = RemoteSourceBundleUploadRequest::seal(offer, &content)
        .expect("seal controller source upload");
    let trust = fixture
        .db
        .task_board_remote_operation_trust_fence(HOST_ID)
        .await
        .expect("load source upload trust");
    fixture
        .db
        .claim_task_board_remote_source_bundle_upload_io_authority_fenced(&request, HOST_ID, &trust)
        .await
        .expect("claim source upload authority");
    let response =
        RemoteSourceBundleUploadResponse::seal(&request, REMOTE_EXECUTOR_CLAIMED_AT.into())
            .expect("seal source upload response");
    fixture
        .db
        .record_task_board_remote_source_bundle_upload_response(&request, &response, HOST_ID)
        .await
        .expect("store source upload receipt");

    let tls = test_tls_material();
    let (endpoint, requests) =
        super::controller_authority_test_support::spawn_probe_server(&tls).await;
    let wrong_host = pinned_controller_for_host(&endpoint, &tls, "executor-b");
    let mut wrong_digest = request.clone();
    change_digest(&mut wrong_digest.request_sha256);
    let controller = pinned_controller(&endpoint, &tls);
    assert!(
        wrong_host
            .upload_source_bundle(&fixture.db, &request)
            .await
            .is_err()
    );
    assert!(
        controller
            .upload_source_bundle(&fixture.db, &wrong_digest)
            .await
            .is_err()
    );
    assert_eq!(requests.await.expect("source conflict probe"), 0);
}

fn bundle_offer(
    template: &super::wire::RemoteOfferRequest,
) -> (super::wire::RemoteOfferRequest, Vec<u8>) {
    let content = b"authenticated controller source bundle".to_vec();
    let artifact = RemoteArtifactEntry {
        relative_path: "source/prior-phase.bundle".into(),
        sha256: hex::encode(Sha256::digest(&content)),
        size_bytes: u64::try_from(content.len()).expect("bundle size"),
        media_type: "application/x-git-bundle".into(),
    };
    let mut offer = template.clone();
    offer.binding.workflow_kind = TaskBoardWorkflowKind::DefaultTask;
    // Prior-phase base must match the bundle's advertised result revision.
    offer.binding.base_revision = RESULT.into();
    offer.source =
        RemoteSourceMaterial::prior_phase_bundle("example/harness", BASE, RESULT, artifact.clone());
    offer.artifacts = RemoteArtifactManifest {
        entries: vec![artifact],
    };
    offer.request_sha256.clear();
    (offer.seal().expect("seal bundle offer"), content)
}

fn change_digest(value: &mut String) {
    let replacement = if value.starts_with('0') { "1" } else { "0" };
    value.replace_range(..1, replacement);
}
