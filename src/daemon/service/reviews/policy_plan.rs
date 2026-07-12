use std::path::Path;
use std::slice::from_ref;

use crate::errors::CliError;
use crate::reviews::policy::{ReviewsPolicyPlan, authored_reviews_policy_plan};
use crate::reviews::{
    ReviewActionPreviewKind, ReviewsPolicyPreviewRequest, ReviewsPolicyPreviewResponse,
    ReviewsPolicyStepType,
};

use super::policy_mapping::preview_step;
use super::preview::{preview_action_target, preview_action_warnings};
use super::token::github_token;

pub(super) fn preview_legacy_reviews_policy_with_token(
    root: &Path,
    request: &ReviewsPolicyPreviewRequest,
) -> Result<ReviewsPolicyPreviewResponse, CliError> {
    let response = preview_legacy_reviews_policy(root, request)?;
    Ok(apply_preview_token_readiness(response, request))
}

pub(super) fn preview_legacy_reviews_policy(
    root: &Path,
    request: &ReviewsPolicyPreviewRequest,
) -> Result<ReviewsPolicyPreviewResponse, CliError> {
    request.validate()?;
    let workflow_id = request.normalized_workflow_id();
    let plan = authored_reviews_policy_plan(root, &workflow_id, &request.target, request.method)?;
    Ok(preview_response(request, workflow_id, &plan))
}

fn apply_preview_token_readiness(
    mut response: ReviewsPolicyPreviewResponse,
    request: &ReviewsPolicyPreviewRequest,
) -> ReviewsPolicyPreviewResponse {
    if response.eligible
        && preview_response_requires_token(&response)
        && github_token(Some(request.target.repository.as_str()))
            .or_else(|| github_token(None))
            .is_none()
    {
        response.eligible = false;
        response.reason = Some(format!(
            "No GitHub token is configured for '{}'",
            request.target.repository
        ));
    }
    response
}

fn preview_response(
    request: &ReviewsPolicyPreviewRequest,
    workflow_id: String,
    plan: &ReviewsPolicyPlan,
) -> ReviewsPolicyPreviewResponse {
    let preview_target = preview_action_target(ReviewActionPreviewKind::Auto, &request.target);
    let mut warnings =
        preview_action_warnings(ReviewActionPreviewKind::Auto, from_ref(&request.target));
    extend_unique(&mut warnings, preview_target.warnings);
    let (eligible, reason) = plan_preview_eligibility(plan);
    ReviewsPolicyPreviewResponse {
        workflow_id,
        subject: request.subject(),
        eligible,
        reason,
        warnings,
        steps: plan.steps.iter().map(preview_step).collect(),
    }
}

fn plan_preview_eligibility(plan: &ReviewsPolicyPlan) -> (bool, Option<String>) {
    if !plan.actionable {
        return (
            false,
            Some(
                plan.reason.clone().unwrap_or_else(|| {
                    "reviews policy run produced no actionable steps".to_owned()
                }),
            ),
        );
    }
    (true, plan.reason.clone())
}

fn preview_response_requires_token(response: &ReviewsPolicyPreviewResponse) -> bool {
    response
        .steps
        .iter()
        .any(|step| step.step_type == ReviewsPolicyStepType::Action)
}

fn extend_unique(target: &mut Vec<String>, additions: Vec<String>) {
    for addition in additions {
        if !target.contains(&addition) {
            target.push(addition);
        }
    }
}
