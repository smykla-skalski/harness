use crate::reviews::{
    ReviewCheckStatus, ReviewMergeableState, ReviewPullRequestState, ReviewReviewStatus,
    ReviewTarget,
};
use crate::task_board::PolicyEvidence;

#[must_use]
pub(crate) fn review_target_policy_evidence(target: &ReviewTarget) -> PolicyEvidence {
    PolicyEvidence {
        checks_green: Some(target.check_status == ReviewCheckStatus::Success),
        reviewer_verdict_approved: Some(target.review_status == ReviewReviewStatus::Approved),
        review_is_open: Some(target.state == ReviewPullRequestState::Open),
        review_is_draft: Some(target.flags.is_draft),
        review_review_required: Some(target.review_status == ReviewReviewStatus::ReviewRequired),
        review_has_no_decision: Some(target.review_status == ReviewReviewStatus::None),
        review_has_merge_conflicts: Some(target.mergeable == ReviewMergeableState::Conflicting),
        review_policy_blocked: Some(target.flags.policy_blocked),
        review_viewer_can_update: Some(target.flags.viewer_can_update),
        ..PolicyEvidence::default()
    }
}
