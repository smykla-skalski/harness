use super::*;

fn sample_item(
    review_status: DependencyUpdateReviewStatus,
    check_status: DependencyUpdateCheckStatus,
    mergeable: DependencyUpdateMergeableState,
    policy_blocked: bool,
) -> DependencyUpdateItem {
    DependencyUpdateItem {
        pull_request_id: "pr_1".into(),
        repository_id: "repo_1".into(),
        repository: "acme/api".into(),
        number: 42,
        title: "chore(deps): bump".into(),
        url: "https://example.com".into(),
        author_login: "renovate[bot]".into(),
        state: DependencyUpdatePullRequestState::Open,
        mergeable,
        review_status,
        check_status,
        policy_blocked,
        is_draft: false,
        head_sha: "abc123".into(),
        labels: Vec::new(),
        checks: Vec::new(),
        reviews: Vec::new(),
        additions: 1,
        deletions: 1,
        created_at: DateTime::parse_from_rfc3339("2026-05-20T12:00:00Z")
            .expect("date")
            .with_timezone(&Utc),
        updated_at: DateTime::parse_from_rfc3339("2026-05-20T12:00:00Z")
            .expect("date")
            .with_timezone(&Utc),
    }
}

#[test]
fn query_request_normalizes_cache_key_inputs() {
    let request = DependencyUpdatesQueryRequest {
        authors: vec![" renovate[bot] ".into(), "renovate[bot]".into()],
        organizations: vec![" acme ".into()],
        repositories: vec!["acme/api".into(), "acme/api".into()],
        exclude_repositories: vec![" acme/old ".into()],
        force_refresh: false,
        cache_max_age_seconds: 0,
    };

    assert_eq!(request.normalized_authors(), vec!["renovate[bot]"]);
    assert_eq!(request.cache_max_age_seconds(), 1);
    assert_eq!(
        request.cache_key(),
        "authors=renovate[bot]|orgs=acme|repos=acme/api|exclude=acme/old"
    );
}

#[test]
fn repository_catalog_request_rejects_empty_and_slashed_organizations() {
    assert!(
        DependencyUpdatesRepositoryCatalogRequest {
            organization: String::new(),
        }
        .validate()
        .is_err()
    );
    assert!(
        DependencyUpdatesRepositoryCatalogRequest {
            organization: "acme/api".into(),
        }
        .validate()
        .is_err()
    );
}

#[test]
fn repository_catalog_request_normalizes_organization() {
    let request = DependencyUpdatesRepositoryCatalogRequest {
        organization: " Acme ".into(),
    };

    assert_eq!(request.normalized_organization(), "acme");
}

#[test]
fn auto_mode_rules_match_helper_contract() {
    let review_required = sample_item(
        DependencyUpdateReviewStatus::ReviewRequired,
        DependencyUpdateCheckStatus::Success,
        DependencyUpdateMergeableState::Mergeable,
        false,
    );
    let approved = sample_item(
        DependencyUpdateReviewStatus::Approved,
        DependencyUpdateCheckStatus::Success,
        DependencyUpdateMergeableState::Mergeable,
        false,
    );
    let blocked = sample_item(
        DependencyUpdateReviewStatus::Approved,
        DependencyUpdateCheckStatus::Success,
        DependencyUpdateMergeableState::Mergeable,
        true,
    );

    assert!(review_required.is_auto_approvable());
    assert!(!review_required.is_ready_to_merge());
    assert!(approved.is_ready_to_merge());
    assert!(!blocked.is_ready_to_merge());
}

#[test]
fn comment_request_rejects_empty_body() {
    let request = DependencyUpdatesCommentRequest {
        targets: vec![DependencyUpdateTarget {
            pull_request_id: "pr_1".into(),
            repository_id: "repo_1".into(),
            repository: "acme/api".into(),
            number: 1,
            url: "https://example.com".into(),
            head_sha: "abc".into(),
            mergeable: DependencyUpdateMergeableState::Mergeable,
            review_status: DependencyUpdateReviewStatus::None,
            check_status: DependencyUpdateCheckStatus::None,
            policy_blocked: false,
            check_suite_ids: Vec::new(),
        }],
        body: "   ".into(),
    };
    assert!(request.validate().is_err());
}

#[test]
fn comment_request_rejects_empty_targets() {
    let request = DependencyUpdatesCommentRequest {
        targets: Vec::new(),
        body: "@renovatebot rebase".into(),
    };
    assert!(request.validate().is_err());
}

#[test]
fn comment_request_accepts_well_formed_payload() {
    let request = DependencyUpdatesCommentRequest {
        targets: vec![DependencyUpdateTarget {
            pull_request_id: "pr_1".into(),
            repository_id: "repo_1".into(),
            repository: "acme/api".into(),
            number: 1,
            url: "https://example.com".into(),
            head_sha: "abc".into(),
            mergeable: DependencyUpdateMergeableState::Mergeable,
            review_status: DependencyUpdateReviewStatus::None,
            check_status: DependencyUpdateCheckStatus::None,
            policy_blocked: false,
            check_suite_ids: Vec::new(),
        }],
        body: "@renovatebot rebase".into(),
    };
    assert!(request.validate().is_ok());
}

#[test]
fn auto_mergeable_accepts_unreviewed_open_prs() {
    let unreviewed = sample_item(
        DependencyUpdateReviewStatus::None,
        DependencyUpdateCheckStatus::Success,
        DependencyUpdateMergeableState::Mergeable,
        false,
    );
    let unreviewed_pending = sample_item(
        DependencyUpdateReviewStatus::None,
        DependencyUpdateCheckStatus::Pending,
        DependencyUpdateMergeableState::Mergeable,
        false,
    );
    let unreviewed_conflicting = sample_item(
        DependencyUpdateReviewStatus::None,
        DependencyUpdateCheckStatus::Success,
        DependencyUpdateMergeableState::Conflicting,
        false,
    );
    let unreviewed_policy_blocked = sample_item(
        DependencyUpdateReviewStatus::None,
        DependencyUpdateCheckStatus::Success,
        DependencyUpdateMergeableState::Mergeable,
        true,
    );
    let changes_requested = sample_item(
        DependencyUpdateReviewStatus::ChangesRequested,
        DependencyUpdateCheckStatus::Success,
        DependencyUpdateMergeableState::Mergeable,
        false,
    );

    assert!(unreviewed.is_ready_to_merge());
    assert!(!unreviewed_pending.is_ready_to_merge());
    assert!(!unreviewed_conflicting.is_ready_to_merge());
    assert!(!unreviewed_policy_blocked.is_ready_to_merge());
    assert!(!changes_requested.is_ready_to_merge());
}

#[test]
fn serialized_item_always_emits_array_fields_for_swift_decoders() {
    let item = sample_item(
        DependencyUpdateReviewStatus::ReviewRequired,
        DependencyUpdateCheckStatus::Success,
        DependencyUpdateMergeableState::Mergeable,
        false,
    );
    let value = serde_json::to_value(&item).expect("serialize");

    let object = value.as_object().expect("item is an object");
    assert!(object.contains_key("labels"), "labels key must be emitted");
    assert!(object.contains_key("checks"), "checks key must be emitted");
    assert!(
        object.contains_key("reviews"),
        "reviews key must be emitted"
    );
    assert!(
        object["labels"].as_array().is_some(),
        "labels must be an array"
    );
    assert!(
        object["checks"].as_array().is_some(),
        "checks must be an array"
    );
    assert!(
        object["reviews"].as_array().is_some(),
        "reviews must be an array"
    );
}

#[test]
fn serialized_action_response_always_emits_results_array() {
    let response = DependencyUpdatesActionResponse {
        summary: "no targets".into(),
        results: Vec::new(),
    };
    let value = serde_json::to_value(&response).expect("serialize");
    let object = value.as_object().expect("response is an object");
    assert!(
        object.contains_key("results"),
        "results key must be emitted"
    );
    assert!(
        object["results"].as_array().is_some(),
        "results must be an array"
    );
}

#[test]
fn serialized_check_emits_details_url_when_present() {
    let check = DependencyUpdateCheck {
        name: "ci".into(),
        status: DependencyUpdateCheckRunStatus::Completed,
        conclusion: DependencyUpdateCheckConclusion::Success,
        check_suite_id: Some("suite-1".into()),
        details_url: Some("https://github.com/acme/api/actions/runs/1".into()),
    };
    let value = serde_json::to_value(&check).expect("serialize");
    let object = value.as_object().expect("check is an object");
    assert_eq!(
        object.get("details_url").and_then(serde_json::Value::as_str),
        Some("https://github.com/acme/api/actions/runs/1")
    );
}

#[test]
fn serialized_catalog_response_always_emits_repositories_array() {
    let response = DependencyUpdatesRepositoryCatalogResponse {
        organization: "acme".into(),
        repositories: Vec::new(),
    };
    let value = serde_json::to_value(&response).expect("serialize");
    let object = value.as_object().expect("response is an object");
    assert!(
        object.contains_key("repositories"),
        "repositories key must be emitted"
    );
    assert!(
        object["repositories"].as_array().is_some(),
        "repositories must be an array"
    );
}

#[test]
fn body_request_rejects_empty_pull_request_id() {
    let request = DependencyUpdatesBodyRequest {
        pull_request_id: "   ".into(),
        force_refresh: false,
        cache_max_age_seconds: 0,
    };
    assert!(request.validate().is_err());
}

#[test]
fn body_request_normalizes_pull_request_id_and_cache_age() {
    let request = DependencyUpdatesBodyRequest {
        pull_request_id: " pr_node ".into(),
        force_refresh: false,
        cache_max_age_seconds: 0,
    };
    assert_eq!(request.normalized_pull_request_id(), "pr_node");
    assert_eq!(request.cache_max_age_seconds(), 1);
    assert!(request.validate().is_ok());
}

fn sample_body_update_request() -> DependencyUpdatesBodyUpdateRequest {
    DependencyUpdatesBodyUpdateRequest {
        pull_request_id: "pr_node".into(),
        expected_prior_body_sha256:
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".into(),
        new_body: "- [x] rebase".into(),
    }
}

#[test]
fn body_update_request_normalizes_pull_request_id_and_hash() {
    let request = DependencyUpdatesBodyUpdateRequest {
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
    request.new_body =
        "x".repeat(DependencyUpdatesBodyUpdateRequest::MAX_BODY_BYTES + 1);
    assert!(request.validate().is_err());
}

#[test]
fn body_update_request_accepts_max_size_body() {
    let mut request = sample_body_update_request();
    request.new_body = "x".repeat(DependencyUpdatesBodyUpdateRequest::MAX_BODY_BYTES);
    assert!(request.validate().is_ok());
}

#[test]
fn body_update_outcome_serializes_snake_case() {
    let updated = serde_json::to_value(DependencyUpdatesBodyUpdateOutcome::Updated)
        .expect("serialize updated");
    assert_eq!(updated, serde_json::json!("updated"));
    let drifted = serde_json::to_value(DependencyUpdatesBodyUpdateOutcome::BodyDrifted)
        .expect("serialize drifted");
    assert_eq!(drifted, serde_json::json!("body_drifted"));
}

#[test]
fn serialized_target_always_emits_check_suite_ids_array() {
    let target = DependencyUpdateTarget {
        pull_request_id: "pr_1".into(),
        repository_id: "repo_1".into(),
        repository: "acme/api".into(),
        number: 1,
        url: "https://example.com".into(),
        head_sha: "abc".into(),
        mergeable: DependencyUpdateMergeableState::Mergeable,
        review_status: DependencyUpdateReviewStatus::None,
        check_status: DependencyUpdateCheckStatus::None,
        policy_blocked: false,
        check_suite_ids: Vec::new(),
    };
    let value = serde_json::to_value(&target).expect("serialize");
    let object = value.as_object().expect("target is an object");
    assert!(
        object.contains_key("check_suite_ids"),
        "check_suite_ids key must be emitted"
    );
}
