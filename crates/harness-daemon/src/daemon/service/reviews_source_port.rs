use crate::reviews::{
    ReviewItem, ReviewsActionResponse, ReviewsApproveRequest, ReviewsQueryRequest,
    ReviewsQueryResponse,
};
use harness_kernel::errors::CliError;

pub(crate) struct RepositoryReviewsSnapshot {
    pub(crate) response: ReviewsQueryResponse,
    pub(crate) github_data_revision: u64,
}

pub(crate) async fn query_repository_reviews(
    request: &ReviewsQueryRequest,
) -> Result<RepositoryReviewsSnapshot, CliError> {
    let (response, github_data_revision) =
        super::reviews::query_repository_reviews_snapshot_parts(request).await?;
    Ok(RepositoryReviewsSnapshot {
        response,
        github_data_revision,
    })
}

pub(crate) async fn resolve_exact_pull_request(
    repository: &str,
    number: u64,
) -> Result<ReviewItem, CliError> {
    super::reviews::resolve_exact_pull_request(repository, number).await
}

pub(crate) async fn approve_pull_requests(
    request: &ReviewsApproveRequest,
) -> Result<ReviewsActionResponse, CliError> {
    super::reviews::approve_reviews(request).await
}
