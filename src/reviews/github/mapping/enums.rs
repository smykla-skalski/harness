use super::super::{
    ReviewCheckConclusion, ReviewCheckRunStatus, ReviewMergeableState, ReviewPullRequestState,
    ReviewReviewEventState, ReviewReviewStatus,
};

pub(in crate::reviews::github) fn map_pull_request_state(
    value: Option<&str>,
) -> ReviewPullRequestState {
    match value {
        Some("OPEN") => ReviewPullRequestState::Open,
        Some("CLOSED") => ReviewPullRequestState::Closed,
        Some("MERGED") => ReviewPullRequestState::Merged,
        _ => ReviewPullRequestState::Unknown,
    }
}

pub(in crate::reviews::github) fn map_mergeable_state(
    value: Option<&str>,
) -> ReviewMergeableState {
    match value {
        Some("MERGEABLE") => ReviewMergeableState::Mergeable,
        Some("CONFLICTING") => ReviewMergeableState::Conflicting,
        _ => ReviewMergeableState::Unknown,
    }
}

pub(in crate::reviews::github) fn map_review_status(value: Option<&str>) -> ReviewReviewStatus {
    match value {
        Some("APPROVED") => ReviewReviewStatus::Approved,
        Some("CHANGES_REQUESTED") => ReviewReviewStatus::ChangesRequested,
        Some("REVIEW_REQUIRED") => ReviewReviewStatus::ReviewRequired,
        _ => ReviewReviewStatus::None,
    }
}

pub(in crate::reviews::github) fn map_check_run_status(
    value: Option<&str>,
) -> ReviewCheckRunStatus {
    match value {
        Some("COMPLETED") => ReviewCheckRunStatus::Completed,
        Some("IN_PROGRESS") => ReviewCheckRunStatus::InProgress,
        Some("QUEUED") => ReviewCheckRunStatus::Queued,
        Some("REQUESTED") => ReviewCheckRunStatus::Requested,
        Some("WAITING") => ReviewCheckRunStatus::Waiting,
        _ => ReviewCheckRunStatus::Unknown,
    }
}

pub(in crate::reviews::github) fn map_check_conclusion(
    value: Option<&str>,
) -> ReviewCheckConclusion {
    match value {
        Some("SUCCESS") => ReviewCheckConclusion::Success,
        Some("FAILURE") => ReviewCheckConclusion::Failure,
        Some("NEUTRAL") => ReviewCheckConclusion::Neutral,
        Some("CANCELLED") => ReviewCheckConclusion::Cancelled,
        Some("TIMED_OUT") => ReviewCheckConclusion::TimedOut,
        Some("ACTION_REQUIRED") => ReviewCheckConclusion::ActionRequired,
        Some("SKIPPED") => ReviewCheckConclusion::Skipped,
        Some("STALE") => ReviewCheckConclusion::Stale,
        Some("STARTUP_FAILURE") => ReviewCheckConclusion::StartupFailure,
        _ => ReviewCheckConclusion::None,
    }
}

pub(in crate::reviews::github) fn map_status_context_conclusion(
    value: Option<&str>,
) -> ReviewCheckConclusion {
    match value {
        Some("SUCCESS") => ReviewCheckConclusion::Success,
        Some("FAILURE" | "ERROR") => ReviewCheckConclusion::Failure,
        _ => ReviewCheckConclusion::None,
    }
}

pub(in crate::reviews::github) fn map_review_event_state(
    value: Option<&str>,
) -> ReviewReviewEventState {
    match value {
        Some("APPROVED") => ReviewReviewEventState::Approved,
        Some("CHANGES_REQUESTED") => ReviewReviewEventState::ChangesRequested,
        Some("COMMENTED") => ReviewReviewEventState::Commented,
        Some("DISMISSED") => ReviewReviewEventState::Dismissed,
        Some("PENDING") => ReviewReviewEventState::Pending,
        _ => ReviewReviewEventState::Unknown,
    }
}
