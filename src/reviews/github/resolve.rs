use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use serde::Deserialize;
use serde_json::json;

use crate::errors::CliError;
use crate::github_api::{GitHubCachePolicy, GitHubPriority, GitHubRequestDescriptor};
use crate::reviews::backports::BackportDetector;

use super::client::{ReviewsFetchByIds, ReviewsGitHubClient};
use super::coverage::log_check_details_url_coverage;
use super::ingest::ingest_nodes_chunk;
use super::mapping::{NodeContinuation, apply_policy_review_metadata};
use super::pagination::resolve_continuation;
use super::types::SearchNode;
use super::{ReviewItem, ReviewRepositoryLabel, ReviewsPullRequestResolveRequest};

pub(super) const PULL_REQUEST_BY_REFERENCE_QUERY: &str = r"
query ReviewPullRequestByReference($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id
      number
      title
      url
      state
      mergeable
      isDraft
      viewerCanMergeAsAdmin
      reviewDecision
      autoMergeRequest { enabledAt }
      headRefOid
      baseRefName
      author { login avatarUrl }
      authorAssociation
      viewerLatestReviewRequest { id }
      repository {
        id
        nameWithOwner
        defaultBranchRef { name }
        labels(first: 100) {
          pageInfo { hasNextPage endCursor }
          nodes {
            name
            color
            description
          }
        }
      }
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              contexts(first: 100) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  ... on CheckRun {
                    name
                    status
                    conclusion
                    url
                    checkSuite { id }
                  }
                  ... on StatusContext {
                    context
                    state
                    targetUrl
                  }
                }
              }
            }
          }
        }
      }
      baseRef {
        branchProtectionRule {
          requiresApprovingReviews
          requiredApprovingReviewCount
          requiredStatusCheckContexts
          requiredStatusChecks { context }
        }
      }
      reviews(first: 100) {
        pageInfo { hasNextPage endCursor }
        nodes {
          author { login avatarUrl }
          state
        }
      }
      labels(first: 100) {
        pageInfo { hasNextPage endCursor }
        nodes { name }
      }
      additions
      deletions
      createdAt
      updatedAt
      viewerCanUpdate
    }
  }
}
";

#[derive(Debug, Deserialize)]
struct PullRequestByReferenceResponse {
    repository: Option<PullRequestByReferenceRepository>,
}

#[derive(Debug, Deserialize)]
struct PullRequestByReferenceRepository {
    #[serde(rename = "pullRequest")]
    pull_request: Option<SearchNode>,
}

impl ReviewsGitHubClient {
    pub(crate) async fn fetch_by_references(
        &self,
        request: &ReviewsPullRequestResolveRequest,
        viewer_login: Option<&str>,
    ) -> Result<ReviewsFetchByIds, CliError> {
        let mut items: Vec<ReviewItem> = Vec::with_capacity(request.references.len());
        let mut continuations: Vec<NodeContinuation> = Vec::new();
        let mut missing = Vec::new();
        let mut repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>> = BTreeMap::new();
        let mut repository_label_continuation_seen: BTreeSet<String> = BTreeSet::new();
        let backport_detector = BackportDetector::from_resolve(request)?;
        for reference in request.normalized_references() {
            let repository = reference.normalized_repository();
            let Some((owner, name)) = repository.split_once('/') else {
                continue;
            };
            let response = self
                .fetch_one_reference(owner, name, reference.number)
                .await?;
            let key = reference.key();
            ingest_nodes_chunk(
                vec![
                    response
                        .repository
                        .and_then(|repository| repository.pull_request),
                ],
                &[key],
                backport_detector.as_ref(),
                &mut items,
                &mut continuations,
                &mut missing,
                &mut repository_labels,
                &mut repository_label_continuation_seen,
            )?;
        }
        for continuation in continuations {
            if let Some(item) = items
                .iter_mut()
                .find(|item| item.pull_request_id == continuation.pull_request_id)
            {
                resolve_continuation(&self.client, item, &mut repository_labels, continuation)
                    .await?;
            }
        }
        apply_policy_review_metadata(&mut items, viewer_login);
        log_check_details_url_coverage(&items);
        Ok(ReviewsFetchByIds {
            items,
            missing,
            repository_labels,
        })
    }

    async fn fetch_one_reference(
        &self,
        owner: &str,
        name: &str,
        number: u64,
    ) -> Result<PullRequestByReferenceResponse, CliError> {
        self.client
            .graphql(
                GitHubRequestDescriptor::graphql(
                    "reviews.pull_request_by_reference",
                    GitHubPriority::FreshRead,
                    GitHubCachePolicy::read_through(
                        Duration::from_mins(5),
                        Duration::from_hours(1),
                    ),
                ),
                json!({
                    "query": PULL_REQUEST_BY_REFERENCE_QUERY,
                    "variables": {
                        "owner": owner,
                        "name": name,
                        "number": number,
                    },
                }),
            )
            .await
            .map(|response| response.body)
    }
}
