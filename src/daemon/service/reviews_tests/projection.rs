use crate::reviews::{
    ReviewAuthorAssociation, ReviewCheckStatus, ReviewItem, ReviewMergeableState,
    ReviewPullRequestState, ReviewReviewStatus, ReviewsQueryRequest, ReviewsQueryResponse,
};

use super::super::{cached_query_response, store_cached_query_response};
use super::parsed;

fn one_repo_item(repository: &str, pr_id: &str) -> ReviewItem {
    ReviewItem {
        pull_request_id: pr_id.into(),
        repository_id: format!("{repository}#repo_id"),
        repository: repository.into(),
        number: 1,
        title: "chore(deps): bump".into(),
        url: format!("https://example.com/{pr_id}"),
        base_ref_name: None,
        default_branch_name: None,
        backport_source: None,
        author_login: "renovate[bot]".into(),
        author_avatar_url: None,
        author_association: ReviewAuthorAssociation::None,
        state: ReviewPullRequestState::Open,
        mergeable: ReviewMergeableState::Mergeable,
        review_status: ReviewReviewStatus::ReviewRequired,
        check_status: ReviewCheckStatus::Success,
        flags: crate::reviews::ReviewItemFlags {
            policy_blocked: false,
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
        created_at: parsed("2026-05-20T12:00:00Z"),
        updated_at: parsed("2026-05-20T12:00:00Z"),
        required_failed_check_names: Vec::new(),
        required_approving_review_count: None,
        has_conflict_markers: None,
        viewer_has_active_approval: None,
        auto_merge_enabled: None,
        approval_requirement_satisfied_after_viewer_approval: None,
    }
}

fn base_request_with_authors(authors: &[&str]) -> ReviewsQueryRequest {
    ReviewsQueryRequest {
        authors: authors.iter().map(|a| (*a).to_string()).collect(),
        organizations: vec!["acme".into()],
        repositories: vec!["acme/api".into(), "acme/web".into()],
        exclude_repositories: vec!["acme/legacy".into()],
        force_refresh: false,
        cache_max_age_seconds: 600,
        ..ReviewsQueryRequest::default()
    }
}

#[test]
fn repository_only_request_strips_orgs_and_keeps_excludes() {
    let request = base_request_with_authors(&["per-repo-strip-author"]);
    let scoped = request.repository_only_request("acme/api");

    assert_eq!(scoped.authors, vec!["per-repo-strip-author".to_string()]);
    assert!(scoped.organizations.is_empty());
    assert_eq!(scoped.repositories, vec!["acme/api".to_string()]);
    assert_eq!(scoped.exclude_repositories, vec!["acme/legacy".to_string()]);
    assert_eq!(scoped.force_refresh, request.force_refresh);
    assert_eq!(
        scoped.cache_max_age_seconds,
        request.cache_max_age_seconds()
    );
}

#[test]
fn cache_key_isolates_per_repo_requests() {
    let request = base_request_with_authors(&["per-repo-key-author"]);
    let scoped_a = request.repository_only_request("acme/api");
    let scoped_b = request.repository_only_request("acme/web");

    assert_ne!(
        scoped_a.cache_key(),
        scoped_b.cache_key(),
        "per-repo requests must hash to distinct cache keys"
    );
    assert_ne!(
        scoped_a.cache_key(),
        request.cache_key(),
        "one-repo cache key must differ from the multi-repo bulk key"
    );
}

#[test]
fn cached_query_response_returns_only_its_repo_bucket() {
    let request = base_request_with_authors(&["per-repo-cache-author"]);
    let scoped_a = request.repository_only_request("acme/api");
    let scoped_b = request.repository_only_request("acme/web");

    let response_a = ReviewsQueryResponse::new(
        vec![one_repo_item("acme/api", "pr_iso_a")],
        "2026-05-21T00:00:00Z".into(),
    );
    let response_b = ReviewsQueryResponse::new(
        vec![one_repo_item("acme/web", "pr_iso_b")],
        "2026-05-21T00:00:00Z".into(),
    );
    store_cached_query_response(scoped_a.cache_key(), &response_a);
    store_cached_query_response(scoped_b.cache_key(), &response_b);

    let hit_a = cached_query_response(&scoped_a.cache_key(), 600).expect("cache hit for acme/api");
    let hit_b = cached_query_response(&scoped_b.cache_key(), 600).expect("cache hit for acme/web");

    assert_eq!(hit_a.items.len(), 1);
    assert_eq!(hit_a.items[0].repository, "acme/api");
    assert_eq!(hit_a.items[0].pull_request_id, "pr_iso_a");
    assert!(hit_a.from_cache);

    assert_eq!(hit_b.items.len(), 1);
    assert_eq!(hit_b.items[0].repository, "acme/web");
    assert_eq!(hit_b.items[0].pull_request_id, "pr_iso_b");
    assert!(hit_b.from_cache);
}
