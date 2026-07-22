use sha2::{Digest as _, Sha256};

use super::remote_assignment_test_support::{
    DEADLINE, HOST, LEASE_EXPIRES, NOW, REPOSITORY, controller_fixture,
};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteSourceBundleUploadRequest,
    RemoteSourceBundleUploadResponse, RemoteSourceMaterial,
};
use crate::task_board::TaskBoardWorkflowKind;

const BASE: &str = "1111111111111111111111111111111111111111";
const RESULT: &str = "2222222222222222222222222222222222222222";

#[tokio::test]
async fn controller_source_upload_receipt_is_current_trust_fenced_and_restart_safe() {
    let fixture = controller_fixture(1).await;
    let (offer, content) = bundle_offer(&fixture.request);
    insert_central_offer(&fixture.db, &offer).await;
    let request = RemoteSourceBundleUploadRequest::seal(offer.clone(), &content)
        .expect("seal controller source upload");
    let trust = fixture
        .db
        .task_board_remote_operation_trust_fence(HOST)
        .await
        .expect("load source upload trust");
    assert!(
        fixture
            .db
            .claim_task_board_remote_source_bundle_upload_io_authority_fenced(
                &request, HOST, &trust,
            )
            .await
            .expect("claim source upload authority")
    );
    let response = RemoteSourceBundleUploadResponse::seal(&request, NOW.into())
        .expect("seal source upload response");
    let stored = fixture
        .db
        .record_task_board_remote_source_bundle_upload_response(&request, &response, HOST)
        .await
        .expect("record source upload response");
    assert_eq!(stored.response, response);
    assert_eq!(stored.content.as_deref(), Some(content.as_slice()));

    let reopened = AsyncDaemonDb::connect(&fixture._temp.path().join("controller.db"))
        .await
        .expect("reopen controller after committed upload response");
    let replay = reopened
        .exact_task_board_remote_source_bundle_upload_receipt(&request, HOST)
        .await
        .expect("replay controller upload receipt")
        .expect("controller upload receipt exists");
    assert_eq!(replay, stored);
    assert!(
        !reopened
            .claim_task_board_remote_source_bundle_upload_io_authority_fenced(
                &request, HOST, &trust,
            )
            .await
            .expect("receipt replay needs no new authority")
    );
}

#[tokio::test]
async fn controller_source_upload_receipt_rejects_generation_principal_and_digest_conflicts() {
    let fixture = controller_fixture(1).await;
    let (offer, content) = bundle_offer(&fixture.request);
    insert_central_offer(&fixture.db, &offer).await;
    let request = RemoteSourceBundleUploadRequest::seal(offer.clone(), &content)
        .expect("seal controller source upload");
    let trust = fixture
        .db
        .task_board_remote_operation_trust_fence(HOST)
        .await
        .expect("load source upload trust");
    fixture
        .db
        .claim_task_board_remote_source_bundle_upload_io_authority_fenced(&request, HOST, &trust)
        .await
        .expect("claim source upload authority");
    let response = RemoteSourceBundleUploadResponse::seal(&request, NOW.into())
        .expect("seal source upload response");
    fixture
        .db
        .record_task_board_remote_source_bundle_upload_response(&request, &response, HOST)
        .await
        .expect("record source upload response");

    assert!(
        fixture
            .db
            .exact_task_board_remote_source_bundle_upload_receipt(&request, "other-host")
            .await
            .is_err()
    );
    let mut wrong_epoch_offer = offer;
    wrong_epoch_offer.binding.fencing_epoch += 1;
    wrong_epoch_offer.request_sha256.clear();
    let wrong_epoch_offer = wrong_epoch_offer.seal().expect("seal wrong epoch offer");
    let wrong_epoch = RemoteSourceBundleUploadRequest::seal(wrong_epoch_offer, &content)
        .expect("seal wrong epoch upload");
    assert!(
        fixture
            .db
            .exact_task_board_remote_source_bundle_upload_receipt(&wrong_epoch, HOST)
            .await
            .is_err()
    );
    let mut wrong_assignment = request.clone();
    wrong_assignment.offer.binding.assignment_id.push_str("-other");
    assert!(wrong_assignment.validate().is_err());
    let mut wrong_digest = request;
    change_digest(&mut wrong_digest.request_sha256);
    assert!(wrong_digest.validate().is_err());
}

async fn insert_central_offer(
    db: &AsyncDaemonDb,
    request: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
) {
    db.insert_task_board_remote_source_bundle_offer_for_test(
        request,
        HOST,
        NOW,
        LEASE_EXPIRES,
        DEADLINE,
    )
    .await
    .expect("insert source offer");
}

fn bundle_offer(
    template: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
) -> (
    crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
    Vec<u8>,
) {
    let content = b"controller prior phase bundle bytes".to_vec();
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
    offer.source = RemoteSourceMaterial::prior_phase_bundle(
        REPOSITORY,
        BASE,
        RESULT,
        artifact.clone(),
    );
    offer.artifacts = RemoteArtifactManifest {
        entries: vec![artifact],
    };
    offer.request_sha256.clear();
    (offer.seal().expect("seal source offer"), content)
}

fn change_digest(value: &mut String) {
    let replacement = if value.starts_with('0') { "1" } else { "0" };
    value.replace_range(..1, replacement);
}
