use super::*;

#[test]
fn body_request_rejects_empty_pull_request_id() {
    let request = ReviewsBodyRequest {
        pull_request_id: "   ".into(),
        force_refresh: false,
        cache_max_age_seconds: 0,
    };
    assert!(request.validate().is_err());
}

#[test]
fn body_request_normalizes_pull_request_id_and_cache_age() {
    let request = ReviewsBodyRequest {
        pull_request_id: " pr_node ".into(),
        force_refresh: false,
        cache_max_age_seconds: 0,
    };
    assert_eq!(request.normalized_pull_request_id(), "pr_node");
    assert_eq!(request.cache_max_age_seconds(), 1);
    assert!(request.validate().is_ok());
}

fn sample_body_update_request() -> ReviewsBodyUpdateRequest {
    ReviewsBodyUpdateRequest {
        pull_request_id: "pr_node".into(),
        expected_prior_body_sha256:
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".into(),
        new_body: "- [x] rebase".into(),
    }
}

#[test]
fn body_update_request_normalizes_pull_request_id_and_hash() {
    let request = ReviewsBodyUpdateRequest {
        pull_request_id: "  pr_node  ".into(),
        expected_prior_body_sha256:
            "  ABCDEFabcdef0123456789012345678901234567890123456789012345678901  ".into(),
        new_body: "body".into(),
    };
    assert_eq!(request.normalized_pull_request_id(), "pr_node");
    assert_eq!(
        request.normalized_expected_prior_body_sha256(),
        "abcdefabcdef0123456789012345678901234567890123456789012345678901"
    );
    assert!(request.validate().is_ok());
}

#[test]
fn body_update_request_rejects_empty_pull_request_id() {
    let mut request = sample_body_update_request();
    request.pull_request_id = "   ".into();
    assert!(request.validate().is_err());
}

#[test]
fn body_update_request_rejects_short_hash() {
    let mut request = sample_body_update_request();
    request.expected_prior_body_sha256 = "abc".into();
    assert!(request.validate().is_err());
}

#[test]
fn body_update_request_rejects_non_hex_hash() {
    let mut request = sample_body_update_request();
    request.expected_prior_body_sha256 =
        "g123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".into();
    assert!(request.validate().is_err());
}

#[test]
fn body_update_request_rejects_oversize_body() {
    let mut request = sample_body_update_request();
    request.new_body = "x".repeat(ReviewsBodyUpdateRequest::MAX_BODY_BYTES + 1);
    assert!(request.validate().is_err());
}

#[test]
fn body_update_request_accepts_max_size_body() {
    let mut request = sample_body_update_request();
    request.new_body = "x".repeat(ReviewsBodyUpdateRequest::MAX_BODY_BYTES);
    assert!(request.validate().is_ok());
}

#[test]
fn body_update_outcome_serializes_snake_case() {
    let updated =
        serde_json::to_value(ReviewsBodyUpdateOutcome::Updated).expect("serialize updated");
    assert_eq!(updated, serde_json::json!("updated"));
    let drifted =
        serde_json::to_value(ReviewsBodyUpdateOutcome::BodyDrifted).expect("serialize drifted");
    assert_eq!(drifted, serde_json::json!("body_drifted"));
}

#[test]
fn serialized_target_always_emits_check_suite_ids_array() {
    let target = ReviewTarget {
        pull_request_id: "pr_1".into(),
        repository_id: "repo_1".into(),
        repository: "acme/api".into(),
        number: 1,
        url: "https://example.com".into(),
        state: ReviewPullRequestState::Open,
        head_sha: "abc".into(),
        mergeable: ReviewMergeableState::Mergeable,
        review_status: ReviewReviewStatus::None,
        check_status: ReviewCheckStatus::None,
        flags: ReviewTargetFlags {
            is_draft: false,
            policy_blocked: false,
            viewer_can_update: true,
        },
        viewer_can_merge_as_admin: false,
        required_failed_check_names: Vec::new(),
        check_suite_ids: Vec::new(),
    };
    let value = serde_json::to_value(&target).expect("serialize");
    let object = value.as_object().expect("target is an object");
    assert!(
        object.contains_key("check_suite_ids"),
        "check_suite_ids key must be emitted"
    );
    assert!(
        object.contains_key("viewer_can_update"),
        "viewer_can_update key must be emitted"
    );
}
