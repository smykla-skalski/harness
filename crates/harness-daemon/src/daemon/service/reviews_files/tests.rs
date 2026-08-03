//! Unit tests for the reviews-files service endpoints.

use crate::reviews::{
    ReviewFileViewedState, ReviewFilesViewedTarget,
    ReviewsFilesBlobRequest, ReviewsFilesListRequest, ReviewsFilesPatchRequest,
    ReviewsFilesViewedRequest,
};

use super::{
    fetch_review_file_blob, list_review_files,
    mark_review_files_viewed, patch_review_files,
};

#[tokio::test]
async fn list_request_rejects_empty_pull_request_id() {
    let request = ReviewsFilesListRequest {
        pull_request_id: "   ".into(),
        force_refresh: false,
    };
    let err = list_review_files(&request).await.unwrap_err();
    assert!(err.to_string().to_lowercase().contains("pull_request_id"));
}

#[tokio::test]
async fn patch_request_rejects_empty_pull_request_id() {
    let request = ReviewsFilesPatchRequest {
        pull_request_id: String::new(),
        head_ref_oid_expected: "abc".into(),
        paths: vec!["src/lib.rs".into()],
        number: None,
        repository_full_name: None,
    };
    let err = patch_review_files(&request).await.unwrap_err();
    assert!(err.to_string().to_lowercase().contains("pull_request_id"));
}

#[tokio::test]
async fn patch_request_returns_empty_patches_when_context_is_missing() {
    let request = ReviewsFilesPatchRequest {
        pull_request_id: "PR_1".into(),
        head_ref_oid_expected: "abc".into(),
        paths: vec!["src/lib.rs".into()],
        number: None,
        repository_full_name: None,
    };
    let response = patch_review_files(&request).await.expect("ok");
    assert_eq!(response.pull_request_id, "PR_1");
    assert!(response.patches.is_empty());
    assert!(!response.drifted);
    assert_eq!(response.current_head_ref_oid, "abc");
}

#[tokio::test]
async fn viewed_request_rejects_empty_paths() {
    let request = ReviewsFilesViewedRequest {
        pull_request_id: "PR_1".into(),
        paths: vec![],
    };
    let err = mark_review_files_viewed(&request).await.unwrap_err();
    assert!(err.to_string().contains("path"));
}

#[tokio::test]
async fn blob_request_rejects_empty_oid() {
    let request = ReviewsFilesBlobRequest {
        repository_id: "MDEwOlJlcG9zaXRvcnk".into(),
        oid: String::new(),
        path: "logo.png".into(),
    };
    let err = fetch_review_file_blob(&request).await.unwrap_err();
    assert!(err.to_string().to_lowercase().contains("oid"));
}

#[test]
fn viewed_target_helper_constructs_normalized_payload() {
    let target = ReviewFilesViewedTarget {
        path: "src/lib.rs".into(),
        expected_prior_state: ReviewFileViewedState::Unviewed,
        mark_viewed: true,
    };
    assert_eq!(target.path, "src/lib.rs");
    assert!(target.mark_viewed);
}
