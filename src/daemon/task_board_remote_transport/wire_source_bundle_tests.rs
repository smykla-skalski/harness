use super::wire::{
    RemoteArtifactManifest, RemoteSourceBundleUploadRequest, RemoteSourceBundleUploadResponse,
    RemoteSourceMaterial, RemoteWireError, test_codex_launch,
};
use super::wire_tests::{artifact, offer_request};
use crate::task_board::{TaskBoardExecutionPhase, TaskBoardWorkflowKind};

const BASE: &str = "1111111111111111111111111111111111111111";
const RESULT: &str = "2222222222222222222222222222222222222222";
const STORED_AT: &str = "2026-07-20T12:00:00Z";

#[test]
fn source_bundle_upload_round_trips_exact_generation_and_bytes() {
    let (offer, content) = bundle_offer();
    let upload =
        RemoteSourceBundleUploadRequest::seal(offer, content).expect("seal source bundle upload");
    assert_eq!(upload.validate().expect("validate upload"), content);
    let response = RemoteSourceBundleUploadResponse::seal(&upload, STORED_AT.into())
        .expect("seal upload response");
    response.validate(&upload).expect("validate response");

    let encoded = serde_json::to_value(&upload).expect("encode upload");
    assert_eq!(
        encoded["offer"]["source"]["advertised_ref"],
        format!("refs/harness/task-board/results/{RESULT}")
    );
    assert!(encoded.to_string().find("/tmp/").is_none());
}

#[test]
fn source_bundle_upload_rejects_content_and_generation_tampering() {
    let (offer, content) = bundle_offer();
    let upload =
        RemoteSourceBundleUploadRequest::seal(offer, content).expect("seal source bundle upload");

    let mut content_tampered = upload.clone();
    content_tampered.content_base64.replace_range(..1, "A");
    assert!(content_tampered.validate().is_err());

    let mut offer_tampered = upload;
    let RemoteSourceMaterial::PriorPhaseBundle { advertised_ref, .. } =
        &mut offer_tampered.offer.source
    else {
        unreachable!("bundle source")
    };
    *advertised_ref =
        "refs/harness/task-board/results/ffffffffffffffffffffffffffffffffffffffff".into();
    offer_tampered.offer.request_sha256.clear();
    assert_eq!(
        offer_tampered
            .offer
            .seal()
            .and_then(|offer| offer.validate().map(|()| offer)),
        Err(RemoteWireError::InvalidSourceMaterial)
    );
}

fn bundle_offer() -> (super::wire::RemoteOfferRequest, &'static [u8]) {
    let content = b"sealed git bundle bytes";
    let mut bundle = artifact("source/prior-phase.bundle", content);
    bundle.media_type = "application/x-git-bundle".into();
    let mut offer = offer_request();
    offer.binding.phase = TaskBoardExecutionPhase::Review;
    offer.binding.workflow_kind = TaskBoardWorkflowKind::DefaultTask;
    offer.binding.action_key = "review:reviewer".into();
    // A prior-phase attempt bases on the bundle's advertised result revision, and
    // the launch must match the review phase it now carries.
    offer.binding.base_revision = RESULT.into();
    offer.launch = test_codex_launch(
        TaskBoardExecutionPhase::Review,
        &offer.binding.execution_id,
        "review:reviewer",
        "Review the frozen revision.",
    );
    offer.source =
        RemoteSourceMaterial::prior_phase_bundle("org/repo", BASE, RESULT, bundle.clone());
    offer.artifacts = RemoteArtifactManifest {
        entries: vec![bundle],
    };
    offer.request_sha256.clear();
    (offer.seal().expect("seal bundle offer"), content)
}
