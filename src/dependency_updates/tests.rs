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
