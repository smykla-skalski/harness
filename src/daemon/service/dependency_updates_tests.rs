use chrono::{DateTime, Utc};

use crate::dependency_updates::{
    DependencyUpdateCheckStatus, DependencyUpdateItem, DependencyUpdateMergeableState,
    DependencyUpdatePullRequestState, DependencyUpdateReviewStatus,
    DependencyUpdatesBodyResponse, DependencyUpdatesQueryRequest, DependencyUpdatesQueryResponse,
};

use super::{
    apply_refresh_to_items, cached_body_response, cached_query_response, sha256_hex,
    store_cached_body_response, store_cached_query_response,
};

fn item(
    pr_id: &str,
    state: DependencyUpdatePullRequestState,
    review_status: DependencyUpdateReviewStatus,
) -> DependencyUpdateItem {
    DependencyUpdateItem {
        pull_request_id: pr_id.into(),
        repository_id: "repo_1".into(),
        repository: "acme/api".into(),
        number: 1,
        title: "chore(deps): bump".into(),
        url: "https://example.com".into(),
        author_login: "renovate[bot]".into(),
        state,
        mergeable: DependencyUpdateMergeableState::Mergeable,
        review_status,
        check_status: DependencyUpdateCheckStatus::Success,
        policy_blocked: false,
        is_draft: false,
        head_sha: "abc123".into(),
        labels: Vec::new(),
        checks: Vec::new(),
        reviews: Vec::new(),
        additions: 1,
        deletions: 1,
        created_at: parsed("2026-05-20T12:00:00Z"),
        updated_at: parsed("2026-05-20T12:00:00Z"),
    }
}

fn parsed(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .expect("date")
        .with_timezone(&Utc)
}

#[test]
fn apply_refresh_replaces_matching_open_item() {
    let cached = vec![
        item(
            "pr_1",
            DependencyUpdatePullRequestState::Open,
            DependencyUpdateReviewStatus::ReviewRequired,
        ),
        item(
            "pr_2",
            DependencyUpdatePullRequestState::Open,
            DependencyUpdateReviewStatus::ReviewRequired,
        ),
    ];
    let refreshed = vec![item(
        "pr_1",
        DependencyUpdatePullRequestState::Open,
        DependencyUpdateReviewStatus::Approved,
    )];

    let updated = apply_refresh_to_items(&cached, &refreshed, &[]).expect("changed");
    assert_eq!(updated.len(), 2);
    assert_eq!(
        updated[0].review_status,
        DependencyUpdateReviewStatus::Approved
    );
    assert_eq!(
        updated[1].review_status,
        DependencyUpdateReviewStatus::ReviewRequired
    );
}

#[test]
fn apply_refresh_drops_closed_or_merged_items() {
    let cached = vec![
        item(
            "pr_1",
            DependencyUpdatePullRequestState::Open,
            DependencyUpdateReviewStatus::ReviewRequired,
        ),
        item(
            "pr_2",
            DependencyUpdatePullRequestState::Open,
            DependencyUpdateReviewStatus::ReviewRequired,
        ),
    ];
    let refreshed = vec![item(
        "pr_1",
        DependencyUpdatePullRequestState::Merged,
        DependencyUpdateReviewStatus::Approved,
    )];

    let updated = apply_refresh_to_items(&cached, &refreshed, &[]).expect("changed");
    assert_eq!(updated.len(), 1);
    assert_eq!(updated[0].pull_request_id, "pr_2");
}

#[test]
fn apply_refresh_drops_missing_pull_request_ids() {
    let cached = vec![
        item(
            "pr_1",
            DependencyUpdatePullRequestState::Open,
            DependencyUpdateReviewStatus::ReviewRequired,
        ),
        item(
            "pr_2",
            DependencyUpdatePullRequestState::Open,
            DependencyUpdateReviewStatus::ReviewRequired,
        ),
    ];
    let updated =
        apply_refresh_to_items(&cached, &[], &["pr_1".into()]).expect("changed");
    assert_eq!(updated.len(), 1);
    assert_eq!(updated[0].pull_request_id, "pr_2");
}

#[test]
fn apply_refresh_returns_none_when_no_match() {
    let cached = vec![item(
        "pr_1",
        DependencyUpdatePullRequestState::Open,
        DependencyUpdateReviewStatus::ReviewRequired,
    )];
    let refreshed = vec![item(
        "pr_other",
        DependencyUpdatePullRequestState::Open,
        DependencyUpdateReviewStatus::Approved,
    )];
    assert!(apply_refresh_to_items(&cached, &refreshed, &[]).is_none());
    assert!(apply_refresh_to_items(&cached, &[], &["pr_other".into()]).is_none());
}

#[test]
fn apply_refresh_keeps_closed_item_when_refresh_still_reports_open() {
    let cached = vec![item(
        "pr_1",
        DependencyUpdatePullRequestState::Open,
        DependencyUpdateReviewStatus::ReviewRequired,
    )];
    let refreshed = vec![item(
        "pr_1",
        DependencyUpdatePullRequestState::Open,
        DependencyUpdateReviewStatus::Approved,
    )];
    let updated = apply_refresh_to_items(&cached, &refreshed, &[]).expect("changed");
    assert_eq!(updated.len(), 1);
    assert_eq!(updated[0].state, DependencyUpdatePullRequestState::Open);
    assert_eq!(
        updated[0].review_status,
        DependencyUpdateReviewStatus::Approved
    );
}

fn body_response(pull_request_id: &str, body: &str) -> DependencyUpdatesBodyResponse {
    DependencyUpdatesBodyResponse {
        pull_request_id: pull_request_id.into(),
        body: body.into(),
        pr_updated_at: parsed("2026-05-20T12:00:00Z"),
        fetched_at: "2026-05-21T00:00:00Z".into(),
        from_cache: false,
    }
}

#[test]
fn cached_body_response_returns_none_for_missing_key() {
    assert!(cached_body_response("body-cache-miss-test-pr", 600).is_none());
}

#[test]
fn cached_body_response_flips_from_cache_on_hit() {
    let key = "body-cache-hit-test-pr".to_string();
    let stored = body_response("pr_body_hit", "Some markdown body.");
    store_cached_body_response(key.clone(), &stored);

    let hit = cached_body_response(&key, 600).expect("cache hit within TTL");
    assert!(hit.from_cache, "second read should mark response from_cache");
    assert_eq!(hit.pull_request_id, stored.pull_request_id);
    assert_eq!(hit.body, stored.body);
    assert_eq!(hit.pr_updated_at, stored.pr_updated_at);
    assert_eq!(hit.fetched_at, stored.fetched_at);
}

#[test]
fn cached_body_response_distinguishes_cache_keys() {
    let key_a = "body-cache-key-a-pr".to_string();
    let key_b = "body-cache-key-b-pr";
    let stored = body_response("pr_body_a", "Body A");
    store_cached_body_response(key_a.clone(), &stored);

    assert!(cached_body_response(key_b, 600).is_none());
    let hit = cached_body_response(&key_a, 600).expect("hit for stored key");
    assert_eq!(hit.body, "Body A");
}

#[test]
fn store_cached_body_response_overwrites_existing_entry() {
    let key = "body-cache-overwrite-test-pr".to_string();
    store_cached_body_response(key.clone(), &body_response("pr_body_v1", "first"));
    store_cached_body_response(key.clone(), &body_response("pr_body_v2", "second"));

    let hit = cached_body_response(&key, 600).expect("cache hit");
    assert_eq!(hit.pull_request_id, "pr_body_v2");
    assert_eq!(hit.body, "second");
}

#[test]
fn sha256_hex_is_deterministic_lowercase_hex() {
    let digest = sha256_hex("- [ ] rebase\n");
    assert_eq!(digest.len(), 64);
    assert!(digest.bytes().all(|byte| byte.is_ascii_hexdigit()));
    assert!(digest.bytes().all(|byte| !byte.is_ascii_uppercase()));
    assert_eq!(digest, sha256_hex("- [ ] rebase\n"));
}

#[test]
fn sha256_hex_differs_on_single_char_flip() {
    let unchecked = sha256_hex("- [ ] rebase\n");
    let checked = sha256_hex("- [x] rebase\n");
    assert_ne!(unchecked, checked);
}

#[test]
fn sha256_hex_matches_known_empty_string() {
    assert_eq!(
        sha256_hex(""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
}

fn one_repo_item(repository: &str, pr_id: &str) -> DependencyUpdateItem {
    DependencyUpdateItem {
        pull_request_id: pr_id.into(),
        repository_id: format!("{repository}#repo_id"),
        repository: repository.into(),
        number: 1,
        title: "chore(deps): bump".into(),
        url: format!("https://example.com/{pr_id}"),
        author_login: "renovate[bot]".into(),
        state: DependencyUpdatePullRequestState::Open,
        mergeable: DependencyUpdateMergeableState::Mergeable,
        review_status: DependencyUpdateReviewStatus::ReviewRequired,
        check_status: DependencyUpdateCheckStatus::Success,
        policy_blocked: false,
        is_draft: false,
        head_sha: "abc123".into(),
        labels: Vec::new(),
        checks: Vec::new(),
        reviews: Vec::new(),
        additions: 1,
        deletions: 1,
        created_at: parsed("2026-05-20T12:00:00Z"),
        updated_at: parsed("2026-05-20T12:00:00Z"),
    }
}

fn base_request_with_authors(authors: &[&str]) -> DependencyUpdatesQueryRequest {
    DependencyUpdatesQueryRequest {
        authors: authors.iter().map(|a| (*a).to_string()).collect(),
        organizations: vec!["acme".into()],
        repositories: vec!["acme/api".into(), "acme/web".into()],
        exclude_repositories: vec!["acme/legacy".into()],
        force_refresh: false,
        cache_max_age_seconds: 600,
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

    let response_a = DependencyUpdatesQueryResponse::new(
        vec![one_repo_item("acme/api", "pr_iso_a")],
        "2026-05-21T00:00:00Z".into(),
    );
    let response_b = DependencyUpdatesQueryResponse::new(
        vec![one_repo_item("acme/web", "pr_iso_b")],
        "2026-05-21T00:00:00Z".into(),
    );
    store_cached_query_response(scoped_a.cache_key(), &response_a);
    store_cached_query_response(scoped_b.cache_key(), &response_b);

    let hit_a =
        cached_query_response(&scoped_a.cache_key(), 600).expect("cache hit for acme/api");
    let hit_b =
        cached_query_response(&scoped_b.cache_key(), 600).expect("cache hit for acme/web");

    assert_eq!(hit_a.items.len(), 1);
    assert_eq!(hit_a.items[0].repository, "acme/api");
    assert_eq!(hit_a.items[0].pull_request_id, "pr_iso_a");
    assert!(hit_a.from_cache);

    assert_eq!(hit_b.items.len(), 1);
    assert_eq!(hit_b.items[0].repository, "acme/web");
    assert_eq!(hit_b.items[0].pull_request_id, "pr_iso_b");
    assert!(hit_b.from_cache);
}
