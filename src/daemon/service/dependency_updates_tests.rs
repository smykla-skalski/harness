use chrono::{DateTime, Utc};

use crate::dependency_updates::{
    DependencyUpdateCheckStatus, DependencyUpdateItem, DependencyUpdateMergeableState,
    DependencyUpdatePullRequestState, DependencyUpdateReviewStatus,
};

use super::apply_refresh_to_items;

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
