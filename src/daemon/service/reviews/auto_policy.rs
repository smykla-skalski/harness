use std::sync::Arc;

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;
use crate::reviews::{
    ReviewActionKind, ReviewActionOutcome, ReviewActionPreviewTarget, ReviewActionResult,
    ReviewTarget, ReviewsActionPreviewRequest, ReviewsActionPreviewResponse, ReviewsActionResponse,
    ReviewsCapabilitiesResponse, ReviewsPolicyPreviewRequest, ReviewsPolicyPreviewResponse,
    ReviewsPolicyRunResponse, ReviewsPolicyRunStatus, ReviewsPolicyStepType, ReviewsPolicyWait,
};

use super::policy::preview_reviews_policy_with_audit_db;

pub(super) fn action_response(
    summary_prefix: &str,
    results: Vec<ReviewActionResult>,
) -> ReviewsActionResponse {
    let applied = results
        .iter()
        .filter(|result| result.outcome == ReviewActionOutcome::Applied)
        .count();
    let skipped = results
        .iter()
        .filter(|result| result.outcome == ReviewActionOutcome::Skipped)
        .count();
    let failed = results
        .iter()
        .filter(|result| result.outcome == ReviewActionOutcome::Failed)
        .count();
    ReviewsActionResponse {
        summary: format!("{summary_prefix}: {applied} applied, {skipped} skipped, {failed} failed"),
        results,
    }
}

pub(super) async fn preview_auto_review_action(
    request: &ReviewsActionPreviewRequest,
    database: Option<Arc<AsyncDaemonDb>>,
) -> Result<ReviewsActionPreviewResponse, CliError> {
    let mut warnings = Vec::new();
    let mut targets = Vec::with_capacity(request.targets.len());
    for target in &request.targets {
        let preview = preview_reviews_policy_with_audit_db(
            &ReviewsPolicyPreviewRequest {
                workflow_id: String::new(),
                target: target.clone(),
                method: request.method,
            },
            database.clone(),
        )
        .await?;
        extend_unique_warnings(&mut warnings, &preview.warnings);
        targets.push(ReviewActionPreviewTarget {
            pull_request_id: target.pull_request_id.clone(),
            repository: target.repository.clone(),
            number: target.number,
            eligible: preview.eligible,
            reason: preview.reason,
            warnings: preview.warnings,
        });
    }
    let actionable_count = targets.iter().filter(|target| target.eligible).count();
    let skipped_count = targets.len().saturating_sub(actionable_count);
    Ok(ReviewsActionPreviewResponse {
        action: request.action,
        capabilities: ReviewsCapabilitiesResponse::current(),
        total_count: request.targets.len(),
        actionable_count,
        skipped_count,
        warnings,
        targets,
    })
}

pub(super) fn auto_policy_results_from_run(
    target: &ReviewTarget,
    preview: &ReviewsPolicyPreviewResponse,
    run: &ReviewsPolicyRunResponse,
) -> Vec<ReviewActionResult> {
    let mut results = Vec::new();

    for step in &run.steps {
        if step.step_type != ReviewsPolicyStepType::Action {
            continue;
        }
        let Some(action) = step.action_key.as_deref().and_then(auto_policy_action_kind) else {
            continue;
        };
        results.push(ReviewActionResult {
            repository: target.repository.clone(),
            number: target.number,
            action,
            outcome: ReviewActionOutcome::Applied,
            message: None,
            timeline_entry: None,
        });
    }

    if run.status == ReviewsPolicyRunStatus::Waiting
        && let Some(next_action) = next_auto_policy_action_kind(preview, run)
    {
        results.push(ReviewActionResult {
            repository: target.repository.clone(),
            number: target.number,
            action: next_action,
            outcome: ReviewActionOutcome::Skipped,
            message: Some(auto_policy_wait_message(run.waiting_on.as_ref())),
            timeline_entry: None,
        });
    }

    if results.is_empty() {
        results.push(skipped_auto_policy_result(target, preview));
    }

    results
}

pub(super) fn skipped_auto_policy_result(
    target: &ReviewTarget,
    preview: &ReviewsPolicyPreviewResponse,
) -> ReviewActionResult {
    ReviewActionResult {
        repository: target.repository.clone(),
        number: target.number,
        action: auto_policy_fallback_kind(target, preview),
        outcome: ReviewActionOutcome::Skipped,
        message: Some(
            preview
                .reason
                .clone()
                .unwrap_or_else(|| "reviews policy workflow is not actionable".to_owned()),
        ),
        timeline_entry: None,
    }
}

pub(super) fn failed_auto_policy_result(
    target: &ReviewTarget,
    preview: &ReviewsPolicyPreviewResponse,
    error: &str,
) -> ReviewActionResult {
    ReviewActionResult {
        repository: target.repository.clone(),
        number: target.number,
        action: auto_policy_fallback_kind(target, preview),
        outcome: ReviewActionOutcome::Failed,
        message: Some(error.to_owned()),
        timeline_entry: None,
    }
}

fn next_auto_policy_action_kind(
    preview: &ReviewsPolicyPreviewResponse,
    run: &ReviewsPolicyRunResponse,
) -> Option<ReviewActionKind> {
    preview.steps.iter().skip(run.steps.len()).find_map(|step| {
        (step.step_type == ReviewsPolicyStepType::Action)
            .then(|| step.action_key.as_deref().and_then(auto_policy_action_kind))
            .flatten()
    })
}

fn auto_policy_fallback_kind(
    target: &ReviewTarget,
    preview: &ReviewsPolicyPreviewResponse,
) -> ReviewActionKind {
    preview
        .steps
        .iter()
        .find_map(|step| step.action_key.as_deref().and_then(auto_policy_action_kind))
        .unwrap_or_else(|| {
            if target.is_auto_approvable() {
                ReviewActionKind::AutoApprove
            } else {
                ReviewActionKind::AutoMerge
            }
        })
}

fn auto_policy_action_kind(action_key: &str) -> Option<ReviewActionKind> {
    match action_key {
        "reviews.approve" => Some(ReviewActionKind::AutoApprove),
        "reviews.merge" => Some(ReviewActionKind::AutoMerge),
        _ => None,
    }
}

fn auto_policy_wait_message(wait: Option<&ReviewsPolicyWait>) -> String {
    match wait {
        Some(ReviewsPolicyWait {
            event_key: Some(event_key),
            ..
        }) => format!("waiting for policy event '{event_key}' before continuing"),
        Some(ReviewsPolicyWait {
            duration_seconds: Some(duration_seconds),
            ..
        }) => format!("waiting {duration_seconds}s before continuing the policy workflow"),
        _ => "waiting for the configured policy condition before continuing".to_owned(),
    }
}

fn extend_unique_warnings(target: &mut Vec<String>, additions: &[String]) {
    for addition in additions {
        if !target.contains(addition) {
            target.push(addition.clone());
        }
    }
}
