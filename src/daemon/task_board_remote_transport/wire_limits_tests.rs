use sha2::{Digest as _, Sha256};

use super::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteAttemptBinding,
    RemoteSourceBundleUploadRequest, RemoteSourceBundleUploadResponse, RemoteSourceMaterial,
    RemoteWireError,
};
use super::wire_limits::{
    MAX_REMOTE_OFFER_JSON_BYTES, MAX_REMOTE_RECEIPT_JSON_BYTES,
    MAX_REMOTE_SOURCE_BUNDLE_JSON_BYTES, require_serialized_size,
};
use super::wire_tests::offer_request;

#[test]
fn encoded_receipt_boundary_accepts_exact_max_and_rejects_one_more_byte() {
    let exact = "x".repeat(MAX_REMOTE_RECEIPT_JSON_BYTES - 2);
    require_serialized_size("receipt", &exact, MAX_REMOTE_RECEIPT_JSON_BYTES)
        .expect("exact receipt boundary");

    let oversized = format!("{exact}x");
    assert_eq!(
        require_serialized_size("receipt", &oversized, MAX_REMOTE_RECEIPT_JSON_BYTES),
        Err(RemoteWireError::EnvelopeTooLarge("receipt"))
    );
}

#[test]
fn source_bundle_http_boundary_covers_bounded_base64_prompt_and_metadata() {
    let base64_bytes = (super::wire::MAX_REMOTE_ARTIFACT_BYTES as usize).div_ceil(3) * 4;
    assert_eq!(
        MAX_REMOTE_SOURCE_BUNDLE_JSON_BYTES,
        MAX_REMOTE_OFFER_JSON_BYTES + base64_bytes + 133
    );
}

#[test]
fn echoed_binding_fields_are_bounded_before_receipt_persistence() {
    let mut request = offer_request();
    request.binding.assignment_id = "a".repeat(256);
    request.request_sha256.clear();
    let request = request.seal().expect("maximum assignment id");

    let mut oversized: RemoteAttemptBinding = request.binding;
    oversized.assignment_id.push('a');
    assert_eq!(
        oversized.validate(),
        Err(RemoteWireError::EnvelopeTooLarge("assignment_id"))
    );

    let mut escaped = offer_request().binding;
    escaped.assignment_id = "\u{1f}".repeat(256);
    assert_eq!(
        escaped.validate(),
        Err(RemoteWireError::InvalidToken("assignment_id"))
    );
}

#[test]
fn canonical_source_receipt_stays_bounded_and_escaped_aliases_are_rejected() {
    let content = b"x";
    let repository = format!("{}/{}", "a".repeat(1_023), "b".repeat(1_024));
    let artifact = RemoteArtifactEntry {
        relative_path: "p".repeat(512),
        sha256: hex::encode(Sha256::digest(content)),
        size_bytes: content.len() as u64,
        media_type: "application/x-git-bundle".into(),
    };
    let mut offer = offer_request();
    offer.binding.action_key = "implementation:1".into();
    offer.binding.repository.clone_from(&repository);
    offer.binding.expected_head_revision = None;
    offer.source = RemoteSourceMaterial::repository_snapshot_bundle(
        &repository,
        &offer.binding.base_revision,
        artifact.clone(),
    );
    offer.artifacts = RemoteArtifactManifest {
        entries: vec![artifact],
    };
    offer.request_sha256.clear();
    let offer = offer.seal().expect("maximum canonical source offer");
    let upload = RemoteSourceBundleUploadRequest::seal(offer, content)
        .expect("maximum canonical source upload");
    let response = RemoteSourceBundleUploadResponse::seal(&upload, "2026-07-19T12:00:00Z".into())
        .expect("bounded canonical source receipt");
    require_serialized_size(
        "source_bundle_upload_response",
        &response,
        MAX_REMOTE_RECEIPT_JSON_BYTES,
    )
    .expect("canonical receipt fits immutable receipt cap");

    let mut escaped_path = response.clone();
    escaped_path.artifact.relative_path = "\u{1f}".repeat(512);
    assert_eq!(
        escaped_path.validate_receipt(
            &response.binding,
            &response.offer_request_sha256,
            &response.upload_request_sha256,
            &escaped_path.artifact,
        ),
        Err(RemoteWireError::InvalidManifest)
    );

    let mut escaped_repository = offer_request().binding;
    escaped_repository.repository = format!("{}/{}", "\u{1f}".repeat(1_023), "repo");
    assert_eq!(
        escaped_repository.validate(),
        Err(RemoteWireError::InvalidSourceMaterial)
    );
}
