use chrono::Utc;

use crate::reviews::{
    PullRequestReview, ReviewAuthorAssociation, ReviewCheckStatus, ReviewItem, ReviewItemFlags,
    ReviewMergeableState, ReviewPullRequestState, ReviewReviewEventState, ReviewReviewStatus,
};

use super::apply_policy_review_metadata;

fn review(author: &str, state: ReviewReviewEventState) -> PullRequestReview {
    PullRequestReview {
        author: author.to_owned(),
        author_avatar_url: None,
        state,
    }
}

fn item(required_approvals: u32, reviews: Vec<PullRequestReview>) -> ReviewItem {
    ReviewItem {
        pull_request_id: "pr_1".to_owned(),
        repository_id: "repo_1".to_owned(),
        repository: "acme/api".to_owned(),
        number: 42,
        title: "policy metadata".to_owned(),
        url: "https://example.com/acme/api/pull/42".to_owned(),
        base_ref_name: Some("main".to_owned()),
        default_branch_name: Some("main".to_owned()),
        backport_source: None,
        author_login: "renovate[bot]".to_owned(),
        author_avatar_url: None,
        author_association: ReviewAuthorAssociation::None,
        state: ReviewPullRequestState::Open,
        mergeable: ReviewMergeableState::Mergeable,
        review_status: ReviewReviewStatus::ReviewRequired,
        check_status: ReviewCheckStatus::Success,
        flags: ReviewItemFlags {
            is_draft: false,
            policy_blocked: false,
            viewer_can_update: true,
            viewer_is_requested_reviewer: false,
        },
        viewer_can_merge_as_admin: false,
        head_sha: "abc123".to_owned(),
        labels: Vec::new(),
        checks: Vec::new(),
        reviews,
        additions: 1,
        deletions: 1,
        created_at: Utc::now(),
        updated_at: Utc::now(),
        required_failed_check_names: Vec::new(),
        required_approving_review_count: Some(required_approvals),
        has_conflict_markers: None,
        viewer_has_active_approval: None,
        auto_merge_enabled: None,
        approval_requirement_satisfied_after_viewer_approval: None,
    }
}

#[test]
fn policy_metadata_uses_latest_review_per_author() {
    let mut items = vec![item(
        2,
        vec![
            review("alice", ReviewReviewEventState::Approved),
            review("Viewer", ReviewReviewEventState::Approved),
            review("viewer", ReviewReviewEventState::ChangesRequested),
        ],
    )];

    apply_policy_review_metadata(&mut items, Some("VIEWER"));

    assert_eq!(items[0].viewer_has_active_approval, Some(false));
    assert_eq!(
        items[0].approval_requirement_satisfied_after_viewer_approval,
        Some(true)
    );
}

#[test]
fn policy_metadata_counts_existing_viewer_approval_once() {
    let mut items = vec![item(
        2,
        vec![
            review("alice", ReviewReviewEventState::Approved),
            review("viewer", ReviewReviewEventState::Approved),
        ],
    )];

    apply_policy_review_metadata(&mut items, Some("viewer"));

    assert_eq!(items[0].viewer_has_active_approval, Some(true));
    assert_eq!(
        items[0].approval_requirement_satisfied_after_viewer_approval,
        Some(true)
    );
}

#[test]
fn policy_metadata_handles_missing_viewer_and_zero_required_approvals() {
    let mut items = vec![item(0, Vec::new()), item(2, Vec::new())];

    apply_policy_review_metadata(&mut items, None);

    assert!(items[0].viewer_has_active_approval.is_none());
    assert_eq!(
        items[0].approval_requirement_satisfied_after_viewer_approval,
        Some(true)
    );
    assert!(items[1].viewer_has_active_approval.is_none());
    assert!(
        items[1]
            .approval_requirement_satisfied_after_viewer_approval
            .is_none()
    );
}
