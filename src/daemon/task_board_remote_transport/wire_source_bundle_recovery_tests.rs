use sha2::{Digest as _, Sha256};

use super::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteSourceBundleAbandonRequest,
    RemoteSourceBundleAbandonResponse, RemoteSourceBundleReceiptVerificationResponse,
    RemoteSourceBundleUploadRequest, RemoteSourceBundleUploadResponse, RemoteSourceMaterial,
};

const NOW: &str = "2026-07-20T12:00:00Z";

#[test]
fn absent_source_receipt_seals_one_exact_abandonment_chain() {
    let upload = upload_request();
    let absent = RemoteSourceBundleReceiptVerificationResponse::seal(
        &upload,
        "executor-restarted".into(),
        NOW.into(),
        None,
    )
    .expect("seal absence verification");
    absent.validate(&upload).expect("validate absence");
    let abandon = RemoteSourceBundleAbandonRequest::seal(&upload, absent)
        .expect("seal abandonment request");
    abandon.validate().expect("validate abandonment request");
    let response = RemoteSourceBundleAbandonResponse::seal(
        &abandon,
        "executor-restarted".into(),
        NOW.into(),
    )
    .expect("seal abandonment response");
    response
        .validate(&abandon)
        .expect("validate abandonment response");
    RemoteSourceBundleAbandonRequest::validate_compact_authority(
        &abandon.offer.binding,
        &abandon.offer.request_sha256,
        &abandon.upload_request_sha256,
        &abandon.verified_absence.response_sha256,
        &abandon.request_sha256,
    )
    .expect("recompute compact abandonment authority");

    let mut wrong_generation = abandon.clone();
    wrong_generation.offer.binding.fencing_epoch += 1;
    assert!(wrong_generation.validate().is_err());
    let mut wrong_host = response;
    wrong_host.abandoned_by_host_instance_id = "other-instance".into();
    assert!(wrong_host.validate(&abandon).is_err());

    let mut wrong_offer_digest = abandon.offer.request_sha256.clone();
    change_digest(&mut wrong_offer_digest);
    assert!(
        RemoteSourceBundleAbandonRequest::validate_compact_authority(
            &abandon.offer.binding,
            &wrong_offer_digest,
            &abandon.upload_request_sha256,
            &abandon.verified_absence.response_sha256,
            &abandon.request_sha256,
        )
        .is_err()
    );
}

fn change_digest(value: &mut String) {
    let replacement = if value.starts_with('0') { "1" } else { "0" };
    value.replace_range(..1, replacement);
}

#[test]
fn present_source_receipt_cannot_be_recast_as_abandoned() {
    let upload = upload_request();
    let receipt = RemoteSourceBundleUploadResponse::seal(&upload, NOW.into())
        .expect("seal upload receipt");
    let present = RemoteSourceBundleReceiptVerificationResponse::seal(
        &upload,
        "executor-restarted".into(),
        NOW.into(),
        Some(receipt.clone()),
    )
    .expect("seal present verification");
    assert_eq!(present.receipt, Some(receipt));
    assert!(RemoteSourceBundleAbandonRequest::seal(&upload, present).is_err());
}

fn upload_request() -> RemoteSourceBundleUploadRequest {
    let content = b"source recovery bundle bytes";
    let artifact = RemoteArtifactEntry {
        relative_path: "source/prior-phase.bundle".into(),
        sha256: hex::encode(Sha256::digest(content)),
        size_bytes: u64::try_from(content.len()).expect("bundle size"),
        media_type: "application/x-git-bundle".into(),
    };
    let mut offer = super::wire_tests::offer_request();
    offer.binding.action_key = "implementation:2".into();
    offer.binding.repository = "sample/widgets".into();
    offer.binding.base_revision = "2222222222222222222222222222222222222222".into();
    offer.binding.expected_head_revision = None;
    offer.source = RemoteSourceMaterial::prior_phase_bundle(
        "sample/widgets",
        "1111111111111111111111111111111111111111",
        "2222222222222222222222222222222222222222",
        artifact.clone(),
    );
    offer.artifacts = RemoteArtifactManifest {
        entries: vec![artifact],
    };
    offer.request_sha256.clear();
    let offer = offer.seal().expect("seal source offer");
    RemoteSourceBundleUploadRequest::seal(offer, content).expect("seal source upload")
}
