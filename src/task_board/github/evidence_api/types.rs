use std::collections::BTreeMap;

use serde::Deserialize;

use super::super::evidence::{
    GitHubCheckConclusion, GitHubCheckEvidence, GitHubCheckStatus, GitHubReviewState,
};

pub(super) const PULL_REQUEST_MERGE_EVIDENCE_QUERY: &str = r"
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      number
      url
      isDraft
      baseRefName
      headRefName
      mergeable
      mergeStateStatus
      files(first: 100) {
        pageInfo { hasNextPage endCursor }
        nodes { path }
      }
      reviews(first: 100, states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED]) {
        pageInfo { hasNextPage endCursor }
        nodes {
          submittedAt
          state
          author { login }
        }
      }
      reviewThreads(first: 100) {
        pageInfo { hasNextPage endCursor }
        nodes {
          isResolved
          comments(first: 1) {
            nodes { author { login } }
          }
        }
      }
      commits(last: 1) {
        nodes {
          commit {
            status { contexts { context state } }
            statusCheckRollup {
              contexts(first: 100) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  __typename
                  ... on CheckRun { name status conclusion }
                  ... on StatusContext { context state }
                }
              }
            }
          }
        }
      }
      baseRef {
        branchProtectionRule {
          requiredStatusCheckContexts
          requiredStatusChecks { context }
        }
      }
    }
  }
}
";

pub(super) const FILES_PAGE_QUERY: &str = r"
query($owner: String!, $repo: String!, $number: Int!, $after: String!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      files(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { path }
      }
    }
  }
}
";

pub(super) const REVIEWS_PAGE_QUERY: &str = r"
query($owner: String!, $repo: String!, $number: Int!, $after: String!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviews(first: 100, after: $after, states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED]) {
        pageInfo { hasNextPage endCursor }
        nodes {
          submittedAt
          state
          author { login }
        }
      }
    }
  }
}
";

pub(super) const THREADS_PAGE_QUERY: &str = r"
query($owner: String!, $repo: String!, $number: Int!, $after: String!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          isResolved
          comments(first: 1) {
            nodes { author { login } }
          }
        }
      }
    }
  }
}
";

pub(super) const CHECKS_PAGE_QUERY: &str = r"
query($owner: String!, $repo: String!, $number: Int!, $after: String!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              contexts(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  __typename
                  ... on CheckRun { name status conclusion }
                  ... on StatusContext { context state }
                }
              }
            }
          }
        }
      }
    }
  }
}
";

#[derive(Debug, Deserialize)]
pub(super) struct PullRequestMergeEvidenceResponse {
    repository: Option<GraphqlRepository>,
}

impl PullRequestMergeEvidenceResponse {
    pub(super) fn pull_request(self) -> Option<GraphqlPullRequest> {
        self.repository.and_then(|repo| repo.pull_request)
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct PullRequestPageResponse {
    repository: Option<GraphqlPageRepository>,
}

impl PullRequestPageResponse {
    pub(super) fn pull_request(self) -> Option<GraphqlPullRequestPage> {
        self.repository.and_then(|repo| repo.pull_request)
    }
}

#[derive(Debug, Deserialize)]
struct GraphqlRepository {
    #[serde(rename = "pullRequest")]
    pull_request: Option<GraphqlPullRequest>,
}

#[derive(Debug, Deserialize)]
struct GraphqlPageRepository {
    #[serde(rename = "pullRequest")]
    pull_request: Option<GraphqlPullRequestPage>,
}

#[derive(Debug, Deserialize)]
pub(super) struct GraphqlPullRequest {
    pub(super) number: u64,
    pub(super) url: String,
    #[serde(rename = "isDraft")]
    pub(super) is_draft: bool,
    #[serde(rename = "baseRefName")]
    pub(super) base_ref_name: String,
    #[serde(rename = "headRefName")]
    pub(super) head_ref_name: String,
    pub(super) mergeable: String,
    #[serde(rename = "mergeStateStatus")]
    pub(super) merge_state_status: Option<String>,
    pub(super) files: GitHubGraphqlConnection<GraphqlChangedFile>,
    pub(super) reviews: GitHubGraphqlConnection<GraphqlPullRequestReview>,
    #[serde(rename = "reviewThreads")]
    pub(super) review_threads: GitHubGraphqlConnection<GitHubReviewThreadNode>,
    pub(super) commits: GraphqlCommitConnection,
    #[serde(rename = "baseRef")]
    pub(super) base_ref: Option<GraphqlRef>,
}

impl GraphqlPullRequest {
    pub(super) fn head_commit(&self) -> Option<&GraphqlCommit> {
        self.commits.nodes.last().map(|node| &node.commit)
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct GraphqlPullRequestPage {
    pub(super) files: Option<GitHubGraphqlConnection<GraphqlChangedFile>>,
    pub(super) reviews: Option<GitHubGraphqlConnection<GraphqlPullRequestReview>>,
    #[serde(rename = "reviewThreads")]
    pub(super) review_threads: Option<GitHubGraphqlConnection<GitHubReviewThreadNode>>,
    commits: Option<GraphqlCommitConnection>,
}

impl GraphqlPullRequestPage {
    pub(super) fn head_check_contexts(
        self,
    ) -> Option<GitHubGraphqlConnection<GraphqlStatusCheckContext>> {
        Some(
            self.commits?
                .nodes
                .into_iter()
                .last()?
                .commit
                .status_check_rollup?
                .contexts,
        )
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct GitHubGraphqlConnection<T> {
    #[serde(rename = "pageInfo")]
    pub(super) page_info: GitHubGraphqlPageInfo,
    pub(super) nodes: Vec<T>,
}

#[derive(Debug, Clone, Deserialize)]
pub(super) struct GitHubGraphqlPageInfo {
    #[serde(rename = "hasNextPage")]
    pub(super) has_next_page: bool,
    #[serde(rename = "endCursor")]
    pub(super) end_cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct GraphqlChangedFile {
    pub(super) path: String,
}

#[derive(Debug, Deserialize)]
pub(super) struct GraphqlPullRequestReview {
    #[serde(rename = "submittedAt")]
    submitted_at: String,
    state: String,
    author: Option<GitHubGraphqlActor>,
}

impl GraphqlPullRequestReview {
    pub(super) fn into_rollup(self) -> Option<GitHubReviewRollup> {
        Some(GitHubReviewRollup {
            reviewer: self.author?.login,
            state: match self.state.as_str() {
                "APPROVED" => GitHubReviewState::Approved,
                "CHANGES_REQUESTED" => GitHubReviewState::ChangesRequested,
                "COMMENTED" => GitHubReviewState::Commented,
                "DISMISSED" => GitHubReviewState::Dismissed,
                _ => return None,
            },
            submitted_at: self.submitted_at,
        })
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct GraphqlCommitConnection {
    nodes: Vec<GraphqlCommitNode>,
}

#[derive(Debug, Deserialize)]
struct GraphqlCommitNode {
    commit: GraphqlCommit,
}

#[derive(Debug, Deserialize)]
pub(super) struct GraphqlCommit {
    pub(super) status: Option<GraphqlCombinedStatus>,
    #[serde(rename = "statusCheckRollup")]
    pub(super) status_check_rollup: Option<GraphqlStatusCheckRollup>,
}

#[derive(Debug, Deserialize)]
pub(super) struct GraphqlCombinedStatus {
    pub(super) contexts: Vec<GraphqlStatusContext>,
}

#[derive(Debug, Deserialize)]
pub(super) struct GraphqlStatusContext {
    context: String,
    state: String,
}

impl GraphqlStatusContext {
    pub(super) fn evidence(&self) -> GitHubCheckEvidence {
        GitHubCheckEvidence {
            name: self.context.clone(),
            status: match self.state.as_str() {
                "ERROR" | "FAILURE" | "SUCCESS" => GitHubCheckStatus::Completed,
                "PENDING" | "EXPECTED" => GitHubCheckStatus::Queued,
                _ => GitHubCheckStatus::InProgress,
            },
            conclusion: Some(match self.state.as_str() {
                "SUCCESS" => GitHubCheckConclusion::Success,
                "ERROR" | "FAILURE" => GitHubCheckConclusion::Failure,
                _ => GitHubCheckConclusion::ActionRequired,
            }),
        }
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct GraphqlStatusCheckRollup {
    pub(super) contexts: GitHubGraphqlConnection<GraphqlStatusCheckContext>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "__typename")]
pub(super) enum GraphqlStatusCheckContext {
    CheckRun {
        name: String,
        status: String,
        conclusion: Option<String>,
    },
    StatusContext {
        context: String,
        state: String,
    },
    #[serde(other)]
    Unknown,
}

impl GraphqlStatusCheckContext {
    pub(super) fn evidence(&self) -> Option<GitHubCheckEvidence> {
        match self {
            Self::CheckRun {
                name,
                status,
                conclusion,
            } => Some(GitHubCheckEvidence {
                name: name.clone(),
                status: match status.as_str() {
                    "QUEUED" | "REQUESTED" | "WAITING" | "PENDING" => GitHubCheckStatus::Queued,
                    "COMPLETED" => GitHubCheckStatus::Completed,
                    _ => GitHubCheckStatus::InProgress,
                },
                conclusion: conclusion.as_deref().map(|conclusion| match conclusion {
                    "SUCCESS" => GitHubCheckConclusion::Success,
                    "NEUTRAL" => GitHubCheckConclusion::Neutral,
                    "CANCELLED" => GitHubCheckConclusion::Cancelled,
                    "SKIPPED" => GitHubCheckConclusion::Skipped,
                    "TIMED_OUT" => GitHubCheckConclusion::TimedOut,
                    "ACTION_REQUIRED" => GitHubCheckConclusion::ActionRequired,
                    _ => GitHubCheckConclusion::Failure,
                }),
            }),
            Self::StatusContext { context, state } => Some(
                GraphqlStatusContext {
                    context: context.clone(),
                    state: state.clone(),
                }
                .evidence(),
            ),
            Self::Unknown => None,
        }
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct GraphqlRef {
    #[serde(rename = "branchProtectionRule")]
    pub(super) branch_protection_rule: Option<GraphqlBranchProtectionRule>,
}

#[derive(Debug, Deserialize)]
pub(super) struct GraphqlBranchProtectionRule {
    #[serde(rename = "requiredStatusCheckContexts")]
    pub(super) required_status_check_contexts: Vec<String>,
    #[serde(rename = "requiredStatusChecks")]
    pub(super) required_status_checks: Vec<GraphqlRequiredStatusCheck>,
}

#[derive(Debug, Deserialize)]
pub(super) struct GraphqlRequiredStatusCheck {
    pub(super) context: String,
}

#[derive(Debug, Default)]
pub(super) struct GitHubReviewThreadSummary {
    pub(super) unresolved_by_reviewer: BTreeMap<String, u32>,
}

impl GitHubReviewThreadSummary {
    pub(super) fn add_threads(&mut self, threads: Vec<GitHubReviewThreadNode>) {
        for thread in threads {
            if thread.is_resolved {
                continue;
            }
            let Some(login) = thread
                .comments
                .nodes
                .first()
                .and_then(|comment| comment.author.as_ref())
                .map(|author| author.login.clone())
            else {
                continue;
            };
            *self.unresolved_by_reviewer.entry(login).or_default() += 1;
        }
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct GitHubReviewThreadNode {
    #[serde(rename = "isResolved")]
    is_resolved: bool,
    comments: GitHubGraphqlCommentConnection,
}

#[derive(Debug, Deserialize)]
struct GitHubGraphqlCommentConnection {
    nodes: Vec<GitHubReviewThreadComment>,
}

#[derive(Debug, Deserialize)]
struct GitHubReviewThreadComment {
    author: Option<GitHubGraphqlActor>,
}

#[derive(Debug, Deserialize)]
struct GitHubGraphqlActor {
    login: String,
}

#[derive(Debug)]
pub(super) struct GitHubReviewRollup {
    pub(super) reviewer: String,
    pub(super) state: GitHubReviewState,
    pub(super) submitted_at: String,
}
