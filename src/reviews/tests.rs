use super::*;

mod body_update;

fn sample_item(
    review_status: ReviewReviewStatus,
    check_status: ReviewCheckStatus,
    mergeable: ReviewMergeableState,
    policy_blocked: bool,
) -> ReviewItem {
    ReviewItem {
        pull_request_id: "pr_1".into(),
        repository_id: "repo_1".into(),
        repository: "acme/api".into(),
        number: 42,
        title: "chore(deps): bump".into(),
        url: "https://example.com".into(),
        base_ref_name: None,
        default_branch_name: None,
        backport_source: None,
        author_login: "renovate[bot]".into(),
        author_avatar_url: None,
        author_association: ReviewAuthorAssociation::None,
        state: ReviewPullRequestState::Open,
        mergeable,
        review_status,
        check_status,
        flags: ReviewItemFlags {
            policy_blocked,
            is_draft: false,
            viewer_can_update: true,
            viewer_is_requested_reviewer: false,
        },
        viewer_can_merge_as_admin: false,
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
        required_failed_check_names: Vec::new(),
        required_approving_review_count: None,
        has_conflict_markers: None,
        viewer_has_active_approval: None,
        auto_merge_enabled: None,
        approval_requirement_satisfied_after_viewer_approval: None,
    }
}

#[test]
fn query_request_normalizes_cache_key_inputs() {
    let request = ReviewsQueryRequest {
        authors: vec![" renovate[bot] ".into(), "renovate[bot]".into()],
        organizations: vec![" acme ".into()],
        repositories: vec!["acme/api".into(), "acme/api".into()],
        exclude_repositories: vec![" acme/old ".into()],
        force_refresh: false,
        cache_max_age_seconds: 0,
        ..ReviewsQueryRequest::default()
    };

    assert_eq!(request.normalized_authors(), vec!["renovate[bot]"]);
    assert_eq!(request.cache_max_age_seconds(), 1);
    assert_eq!(
        request.cache_key(),
        concat!(
            "authors=renovate[bot]|orgs=acme|repos=acme/api|exclude=acme/old",
            "|backports=true|backport_patterns=",
            "(?i)\\s*\\(backport\\s+of\\s+#(?P<number>\\d+)\\)\\s*$\u{1f}",
            "(?i)\\s*\\[backport\\s+of\\s+#(?P<number>\\d+)\\]\\s*$",
        )
    );
}

#[test]
fn query_request_accepts_empty_authors_when_scope_is_present() {
    let request = ReviewsQueryRequest {
        authors: Vec::new(),
        organizations: vec!["acme".into()],
        repositories: Vec::new(),
        exclude_repositories: Vec::new(),
        force_refresh: false,
        cache_max_age_seconds: 600,
        ..ReviewsQueryRequest::default()
    };

    assert!(request.validate().is_ok());
}

#[test]
fn query_request_cache_key_includes_backport_detection_settings() {
    let base = ReviewsQueryRequest {
        organizations: vec!["acme".into()],
        backport_patterns: vec![r"(?i)\s*\(backport of #(?P<number>\d+)\)\s*$".into()],
        ..ReviewsQueryRequest::default()
    };
    let disabled = ReviewsQueryRequest {
        backport_detection_enabled: false,
        ..base.clone()
    };
    let custom = ReviewsQueryRequest {
        backport_patterns: vec![r"(?i)\s*\[picked from #(?P<number>\d+)\]\s*$".into()],
        ..base.clone()
    };

    assert_ne!(base.cache_key(), disabled.cache_key());
    assert_ne!(base.cache_key(), custom.cache_key());
}

#[test]
fn query_request_rejects_empty_scope_even_with_authors() {
    let request = ReviewsQueryRequest {
        authors: vec!["renovate[bot]".into()],
        organizations: Vec::new(),
        repositories: Vec::new(),
        exclude_repositories: Vec::new(),
        force_refresh: false,
        cache_max_age_seconds: 600,
        ..ReviewsQueryRequest::default()
    };

    assert!(request.validate().is_err());
}

#[test]
fn repository_catalog_request_rejects_empty_and_slashed_organizations() {
    assert!(
        ReviewsRepositoryCatalogRequest {
            organization: String::new(),
        }
        .validate()
        .is_err()
    );
    assert!(
        ReviewsRepositoryCatalogRequest {
            organization: "acme/api".into(),
        }
        .validate()
        .is_err()
    );
}

#[test]
fn repository_catalog_request_normalizes_organization() {
    let request = ReviewsRepositoryCatalogRequest {
        organization: " Acme ".into(),
    };

    assert_eq!(request.normalized_organization(), "acme");
}

#[test]
fn auto_mode_rules_match_helper_contract() {
    let review_required = sample_item(
        ReviewReviewStatus::ReviewRequired,
        ReviewCheckStatus::Success,
        ReviewMergeableState::Mergeable,
        false,
    );
    let approved = sample_item(
        ReviewReviewStatus::Approved,
        ReviewCheckStatus::Success,
        ReviewMergeableState::Mergeable,
        false,
    );
    let blocked = sample_item(
        ReviewReviewStatus::Approved,
        ReviewCheckStatus::Success,
        ReviewMergeableState::Mergeable,
        true,
    );

    assert!(review_required.is_auto_approvable());
    assert!(!review_required.is_ready_to_merge());
    assert!(approved.is_ready_to_merge());
    assert!(!blocked.is_ready_to_merge());
}

#[test]
fn comment_request_rejects_empty_body() {
    let request = ReviewsCommentRequest {
        targets: vec![ReviewTarget {
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
            has_conflict_markers: None,
            viewer_has_active_approval: None,
            auto_merge_enabled: None,
            approval_requirement_satisfied_after_viewer_approval: None,
        }],
        body: "   ".into(),
    };
    assert!(request.validate().is_err());
}

#[test]
fn comment_request_rejects_empty_targets() {
    let request = ReviewsCommentRequest {
        targets: Vec::new(),
        body: "@renovatebot rebase".into(),
    };
    assert!(request.validate().is_err());
}

#[test]
fn comment_request_accepts_well_formed_payload() {
    let request = ReviewsCommentRequest {
        targets: vec![ReviewTarget {
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
            has_conflict_markers: None,
            viewer_has_active_approval: None,
            auto_merge_enabled: None,
            approval_requirement_satisfied_after_viewer_approval: None,
        }],
        body: "@renovatebot rebase".into(),
    };
    assert!(request.validate().is_ok());
}

#[test]
fn action_preview_request_rejects_empty_targets() {
    let request = ReviewsActionPreviewRequest {
        action: ReviewActionPreviewKind::Merge,
        targets: Vec::new(),
        method: GitHubMergeMethod::Squash,
    };
    assert!(request.validate().is_err());
}

#[test]
fn current_capabilities_advertise_action_preview_schema() {
    let capabilities = ReviewsCapabilitiesResponse::current();

    assert_eq!(capabilities.schema_version, 1);
    assert!(capabilities.features.supports_action_preview);
    assert!(capabilities.features.supports_check_run_links);
    assert!(capabilities.features.supports_repository_sync_health);
    assert!(capabilities.supports_persistent_action_diagnostics);
}

#[test]
fn auto_mergeable_accepts_unreviewed_open_prs() {
    let unreviewed = sample_item(
        ReviewReviewStatus::None,
        ReviewCheckStatus::Success,
        ReviewMergeableState::Mergeable,
        false,
    );
    let unreviewed_pending = sample_item(
        ReviewReviewStatus::None,
        ReviewCheckStatus::Pending,
        ReviewMergeableState::Mergeable,
        false,
    );
    let unreviewed_conflicting = sample_item(
        ReviewReviewStatus::None,
        ReviewCheckStatus::Success,
        ReviewMergeableState::Conflicting,
        false,
    );
    let unreviewed_policy_blocked = sample_item(
        ReviewReviewStatus::None,
        ReviewCheckStatus::Success,
        ReviewMergeableState::Mergeable,
        true,
    );
    let changes_requested = sample_item(
        ReviewReviewStatus::ChangesRequested,
        ReviewCheckStatus::Success,
        ReviewMergeableState::Mergeable,
        false,
    );

    assert!(unreviewed.is_ready_to_merge());
    assert!(!unreviewed_pending.is_ready_to_merge());
    assert!(!unreviewed_conflicting.is_ready_to_merge());
    assert!(!unreviewed_policy_blocked.is_ready_to_merge());
    assert!(!changes_requested.is_ready_to_merge());
}

#[test]
fn auto_approvable_accepts_unreviewed_open_prs() {
    let no_review = sample_item(
        ReviewReviewStatus::None,
        ReviewCheckStatus::Success,
        ReviewMergeableState::Mergeable,
        false,
    );
    let no_review_failing_checks = sample_item(
        ReviewReviewStatus::None,
        ReviewCheckStatus::Failure,
        ReviewMergeableState::Mergeable,
        false,
    );
    let already_approved = sample_item(
        ReviewReviewStatus::Approved,
        ReviewCheckStatus::Success,
        ReviewMergeableState::Mergeable,
        false,
    );

    assert!(no_review.is_auto_approvable());
    assert!(!no_review_failing_checks.is_auto_approvable());
    assert!(!already_approved.is_auto_approvable());
}

#[test]
fn serialized_item_always_emits_array_fields_for_swift_decoders() {
    let item = sample_item(
        ReviewReviewStatus::ReviewRequired,
        ReviewCheckStatus::Success,
        ReviewMergeableState::Mergeable,
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
        object.contains_key("required_failed_check_names"),
        "required_failed_check_names key must be emitted"
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
    assert!(
        object["required_failed_check_names"].as_array().is_some(),
        "required_failed_check_names must be an array"
    );
}

#[test]
fn serialized_action_response_always_emits_results_array() {
    let response = ReviewsActionResponse {
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
    let check = ReviewCheck {
        name: "ci".into(),
        status: ReviewCheckRunStatus::Completed,
        conclusion: ReviewCheckConclusion::Success,
        check_suite_id: Some("suite-1".into()),
        details_url: Some("https://github.com/acme/api/actions/runs/1".into()),
    };
    let value = serde_json::to_value(&check).expect("serialize");
    let object = value.as_object().expect("check is an object");
    assert_eq!(
        object
            .get("details_url")
            .and_then(serde_json::Value::as_str),
        Some("https://github.com/acme/api/actions/runs/1")
    );
}

#[test]
fn serialized_catalog_response_always_emits_repositories_array() {
    let response = ReviewsRepositoryCatalogResponse {
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
