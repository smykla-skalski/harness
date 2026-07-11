use crate::errors::CliError;
use crate::reviews::timeline;
use crate::reviews::{
    ReviewsActionResponse, ReviewsApproveRequest, ReviewsCommentRequest, ReviewsFileCommentRequest,
    ReviewsFileCommentResponse, ReviewsGitHubClient, ReviewsLabelRequest, ReviewsMergeRequest,
    ReviewsRequestReviewRequest, ReviewsRerunChecksRequest,
};

use super::super::reviews_github_policy::{
    ReviewsGitHubMutation, enforce_review_approve_request_policy,
    enforce_review_file_comment_policy, enforce_review_targets_policy,
};
use super::auto_policy::action_response;
use super::token::{github_token, missing_token_error, token_bound_targets};

/// Approve selected dependency update pull requests.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub rejects an approval.
pub async fn approve_reviews(
    request: &ReviewsApproveRequest,
) -> Result<ReviewsActionResponse, CliError> {
    request.validate()?;
    enforce_review_approve_request_policy(request)?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = ReviewsGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .approve(&ReviewsApproveRequest {
                    targets: segment.targets,
                    source: request.source,
                })
                .await?,
        );
    }
    Ok(action_response("Approved dependency updates", results))
}

/// Post a comment on each selected dependency update pull request. Used to
/// nudge bots like Renovate (`@renovatebot rebase`) and Dependabot
/// (`@dependabot recreate`) to recreate their PR head.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub rejects the comment write.
pub async fn comment_on_reviews(
    request: &ReviewsCommentRequest,
) -> Result<ReviewsActionResponse, CliError> {
    request.validate()?;
    enforce_review_targets_policy(ReviewsGitHubMutation::Comment, &request.targets)?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = ReviewsGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .comment(&ReviewsCommentRequest {
                    targets: segment.targets,
                    body: request.body.clone(),
                })
                .await?,
        );
    }
    Ok(action_response("Posted dependency update comment", results))
}

/// Add or reply to an inline pull-request file review comment.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a GitHub token is missing,
/// or GitHub rejects the inline comment mutation.
pub async fn add_review_file_comment(
    request: &ReviewsFileCommentRequest,
) -> Result<ReviewsFileCommentResponse, CliError> {
    request.validate()?;
    enforce_review_file_comment_policy(request)?;
    let repository = request.repository.as_deref();
    let token = github_token(repository)
        .or_else(|| github_token(None))
        .ok_or_else(|| missing_token_error(repository))?;
    let client = ReviewsGitHubClient::new(&token)?;
    let response = client.add_file_comment(request).await?;
    timeline::drain_pull_request_cache(&request.pull_request_id);
    Ok(response)
}

/// Merge selected dependency update pull requests.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub rejects a merge.
pub async fn merge_reviews(
    request: &ReviewsMergeRequest,
) -> Result<ReviewsActionResponse, CliError> {
    request.validate()?;
    enforce_review_targets_policy(ReviewsGitHubMutation::Merge, &request.targets)?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = ReviewsGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .merge(&ReviewsMergeRequest {
                    targets: segment.targets,
                    method: request.method,
                })
                .await?,
        );
    }
    Ok(action_response("Merged dependency updates", results))
}

/// Rerun checks for selected dependency update pull requests.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub rejects the check rerun.
pub async fn rerun_reviews_checks(
    request: &ReviewsRerunChecksRequest,
) -> Result<ReviewsActionResponse, CliError> {
    request.validate()?;
    enforce_review_targets_policy(ReviewsGitHubMutation::RerunChecks, &request.targets)?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = ReviewsGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .rerun_checks(&ReviewsRerunChecksRequest {
                    targets: segment.targets,
                })
                .await?,
        );
    }
    Ok(action_response("Reran dependency update checks", results))
}

/// Add a label to selected dependency update pull requests.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub rejects the label update.
pub async fn add_label_to_reviews(
    request: &ReviewsLabelRequest,
) -> Result<ReviewsActionResponse, CliError> {
    request.validate()?;
    enforce_review_targets_policy(ReviewsGitHubMutation::AddLabel, &request.targets)?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = ReviewsGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .add_label(&ReviewsLabelRequest {
                    targets: segment.targets,
                    label: request.label.clone(),
                })
                .await?,
        );
    }
    Ok(action_response("Labeled dependency updates", results))
}

/// Re-request a fresh review from a specific GitHub login on each target
/// pull request. Reuses the configured token per repository.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub rejects the request-review write.
pub async fn request_review_for_reviews(
    request: &ReviewsRequestReviewRequest,
) -> Result<ReviewsActionResponse, CliError> {
    request.validate()?;
    enforce_review_targets_policy(ReviewsGitHubMutation::RequestReview, &request.targets)?;
    let mut results = Vec::new();
    for segment in token_bound_targets(&request.targets)? {
        let client = ReviewsGitHubClient::new(&segment.token)?;
        results.extend(
            client
                .request_review(&ReviewsRequestReviewRequest {
                    targets: segment.targets,
                    reviewer_login: request.reviewer_login.clone(),
                })
                .await?,
        );
    }
    Ok(action_response("Re-requested review", results))
}
