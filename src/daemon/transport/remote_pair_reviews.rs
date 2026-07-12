use clap::Args;

use crate::daemon::remote_pairing::normalize_remote_reviews_query;
use crate::errors::{CliError, CliErrorKind};
use crate::reviews::ReviewsQueryRequest;

use super::remote::DaemonRemotePairCreateArgs;

#[derive(Debug, Clone, Args)]
pub(super) struct DaemonRemotePairReviewsArgs {
    /// Optional GitHub authors included in the paired client's Reviews query.
    #[arg(long = "reviews-authors", value_delimiter = ',')]
    authors: Vec<String>,
    /// GitHub organizations included in the paired client's Reviews query.
    #[arg(long = "reviews-organizations", value_delimiter = ',')]
    organizations: Vec<String>,
    /// GitHub owner/repository scopes included in the paired client's Reviews query.
    #[arg(long = "reviews-repositories", value_delimiter = ',')]
    repositories: Vec<String>,
    /// GitHub owner/repository scopes excluded from the paired client's Reviews query.
    #[arg(long = "reviews-exclude-repositories", value_delimiter = ',')]
    exclude_repositories: Vec<String>,
    /// Maximum age of cached Reviews data returned to the paired client.
    #[arg(long = "reviews-cache-max-age-seconds")]
    cache_max_age_seconds: Option<u64>,
}

impl DaemonRemotePairCreateArgs {
    pub(crate) fn reviews_query(&self) -> Result<Option<ReviewsQueryRequest>, CliError> {
        let configured = !self.reviews.authors.is_empty()
            || !self.reviews.organizations.is_empty()
            || !self.reviews.repositories.is_empty()
            || !self.reviews.exclude_repositories.is_empty()
            || self.reviews.cache_max_age_seconds.is_some();
        if !configured {
            return Ok(None);
        }
        normalize_remote_reviews_query(&ReviewsQueryRequest {
            authors: self.reviews.authors.clone(),
            organizations: self.reviews.organizations.clone(),
            repositories: self.reviews.repositories.clone(),
            exclude_repositories: self.reviews.exclude_repositories.clone(),
            force_refresh: false,
            cache_max_age_seconds: self
                .reviews
                .cache_max_age_seconds
                .unwrap_or_else(|| ReviewsQueryRequest::default().cache_max_age_seconds),
            ..ReviewsQueryRequest::default()
        })
        .map(Some)
        .map_err(|error| CliErrorKind::workflow_parse(error.to_string()).into())
    }
}
