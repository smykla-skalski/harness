//! GraphQL metadata fetch for the inline-PR Files section.

use crate::errors::{CliError, CliErrorKind};
use crate::reviews::{ReviewsFilesListRequest, ReviewsFilesListResponse, ReviewsGitHubClient};

use super::token::{github_token, missing_token_error};

/// List the changed files for one pull request.
///
/// # Errors
/// Returns `CliError` when the GitHub token is missing or the GraphQL fetch
/// fails.
pub async fn list_review_files(
    request: &ReviewsFilesListRequest,
) -> Result<ReviewsFilesListResponse, CliError> {
    let pull_request_id = request.normalized_pull_request_id();
    if pull_request_id.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "reviews files list: pull_request_id must not be empty",
        )
        .into());
    }
    let token = github_token(None).ok_or_else(|| missing_token_error(None))?;
    let client = ReviewsGitHubClient::new(&token)?;
    client.fetch_pull_request_files(request).await
}
