//! Preview helpers for `preview_review_action`.
//!
//! Pure functions that classify each target's eligibility for a queued action
//! and assemble the per-target and aggregate warning lists shown in the UI.

use crate::reviews::{
    ReviewActionPreviewKind, ReviewActionPreviewTarget, ReviewCheckStatus, ReviewMergeableState,
    ReviewPullRequestState, ReviewReviewStatus, ReviewTarget,
};

use super::token::github_token;

pub(super) fn preview_action_target(
    action: ReviewActionPreviewKind,
    target: &ReviewTarget,
) -> ReviewActionPreviewTarget {
    let token_available =
        github_token(Some(target.repository.as_str())).or_else(|| github_token(None));
    let reason = if token_available.is_none() {
        Some(format!(
            "No GitHub token is configured for '{}'",
            target.repository
        ))
    } else {
        preview_action_blocker(action, target)
    };
    ReviewActionPreviewTarget {
        pull_request_id: target.pull_request_id.clone(),
        repository: target.repository.clone(),
        number: target.number,
        eligible: reason.is_none(),
        reason,
        warnings: preview_target_warnings(action, target),
    }
}

fn preview_action_blocker(
    action: ReviewActionPreviewKind,
    target: &ReviewTarget,
) -> Option<String> {
    if !target.flags.viewer_can_update {
        return Some("Current GitHub token cannot update this pull request".to_string());
    }
    if target.state != ReviewPullRequestState::Open {
        return Some("Pull request is not open".to_string());
    }
    preview_action_kind_blocker(action, target)
}

fn blocker_unless(ok: bool, msg: &str) -> Option<String> {
    if ok { None } else { Some(msg.to_string()) }
}

fn merge_blocker(target: &ReviewTarget) -> Option<String> {
    if target.flags.is_draft {
        return Some("Draft pull requests cannot be merged".to_string());
    }
    if target.mergeable == ReviewMergeableState::Conflicting {
        return Some("Merge conflicts must be resolved before merging".to_string());
    }
    None
}

fn preview_action_kind_blocker(
    action: ReviewActionPreviewKind,
    target: &ReviewTarget,
) -> Option<String> {
    match action {
        ReviewActionPreviewKind::Approve => blocker_unless(
            target.can_attempt_manual_approval(),
            "Pull request does not need manual approval",
        ),
        ReviewActionPreviewKind::Merge => merge_blocker(target),
        ReviewActionPreviewKind::RerunChecks => blocker_unless(
            target.can_attempt_rerun_checks(),
            "No rerunnable check suites were reported",
        ),
        ReviewActionPreviewKind::AddLabel => blocker_unless(
            target.can_add_label(),
            "Labels can only be added to open pull requests",
        ),
        ReviewActionPreviewKind::Auto => blocker_unless(
            target.is_auto_approvable() || target.is_auto_mergeable(),
            "Pull request is not eligible for auto mode",
        ),
    }
}

pub(super) fn preview_action_warnings(
    action: ReviewActionPreviewKind,
    targets: &[ReviewTarget],
) -> Vec<String> {
    let mut warnings = Vec::new();
    let failing = targets
        .iter()
        .filter(|target| target.check_status == ReviewCheckStatus::Failure)
        .count();
    if matches!(
        action,
        ReviewActionPreviewKind::Approve | ReviewActionPreviewKind::Merge
    ) && failing > 0
    {
        warnings.push(counted_warning(
            failing,
            "pull request has failing checks",
            "pull requests have failing checks",
        ));
    }
    let policy_blocked = targets
        .iter()
        .filter(|target| target.flags.policy_blocked)
        .count();
    if policy_blocked > 0 {
        warnings.push(counted_warning(
            policy_blocked,
            "pull request is policy-blocked",
            "pull requests are policy-blocked",
        ));
    }
    warnings
}

fn preview_target_warnings(action: ReviewActionPreviewKind, target: &ReviewTarget) -> Vec<String> {
    let mut warnings = Vec::new();
    if matches!(
        action,
        ReviewActionPreviewKind::Approve | ReviewActionPreviewKind::Merge
    ) && target.check_status == ReviewCheckStatus::Failure
    {
        if target.required_failed_check_names.is_empty() {
            warnings.push("Checks are failing".to_string());
        } else if target.viewer_can_merge_as_admin && action == ReviewActionPreviewKind::Merge {
            warnings.push(format!(
                "Required checks are failing: {}. Admin merge can bypass branch protections.",
                target.required_failed_check_names.join(", ")
            ));
        } else {
            warnings.push(format!(
                "Required checks are failing: {}",
                target.required_failed_check_names.join(", ")
            ));
        }
    }
    if target.review_status == ReviewReviewStatus::ChangesRequested {
        warnings.push("A reviewer requested changes".to_string());
    }
    if target.flags.policy_blocked {
        warnings.push("Review policy is blocking this pull request".to_string());
    }
    warnings
}

fn counted_warning(count: usize, singular: &str, plural: &str) -> String {
    if count == 1 {
        format!("1 {singular}")
    } else {
        format!("{count} {plural}")
    }
}
