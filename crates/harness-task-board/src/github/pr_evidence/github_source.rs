use std::collections::BTreeMap;

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::json;

use harness_github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_workspace::workspace::utc_now;

use super::gates::{
    CheckGate, CheckState, Mergeability, PullRequestMergeGates, ReviewDecision, ReviewGate,
};
use super::{
    PullRequestEvidence, PullRequestEvidenceRead, PullRequestEvidenceSource, PullRequestIdentity,
    PullRequestLifecycle,
};

const PULL_REQUEST_EVIDENCE_QUERY: &str = r"
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      number
      url
      headRefOid
      isDraft
      state
      mergeable
      viewerCanUpdate
      viewerCanMergeAsAdmin
      reviewDecision
      author { login }
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              contexts(first: 100) {
                nodes {
                  __typename
                  ... on CheckRun { name status conclusion detailsUrl }
                  ... on StatusContext { context state targetUrl }
                }
              }
            }
          }
        }
      }
      reviews(first: 100, states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED]) {
        nodes {
          state
          submittedAt
          author { login }
        }
      }
      baseRef {
        branchProtectionRule {
          requiredApprovingReviewCount
          requiredStatusCheckContexts
          requiredStatusChecks { context }
        }
      }
    }
  }
}
";

/// Reads fresh pull request evidence from GitHub's GraphQL API with a no-store,
/// fresh-read cache policy, so a decision never rests on a cached snapshot.
pub struct GitHubPullRequestEvidenceSource<'client> {
    client: &'client GitHubProtectedClient,
}

impl<'client> GitHubPullRequestEvidenceSource<'client> {
    #[must_use]
    pub fn new(client: &'client GitHubProtectedClient) -> Self {
        Self { client }
    }
}

#[async_trait]
impl PullRequestEvidenceSource for GitHubPullRequestEvidenceSource<'_> {
    async fn read_pull_request_evidence(
        &self,
        identity: &PullRequestIdentity,
    ) -> Result<PullRequestEvidenceRead, CliError> {
        let response: PullRequestEvidenceResponse = self
            .client
            .graphql(
                evidence_descriptor(),
                json!({
                    "query": PULL_REQUEST_EVIDENCE_QUERY,
                    "variables": {
                        "owner": identity.owner(),
                        "repo": identity.repo(),
                        "number": identity.number,
                    },
                }),
            )
            .await
            .map(|response| response.body)?;
        pull_request_evidence_from_response(identity, response, utc_now())
    }
}

/// Project a decoded GraphQL response onto the shared evidence type.
///
/// A `null` repository or pull request node is a `Missing` read, not an error -
/// the provider answered and the pull request is absent. An unrecognized
/// lifecycle state is a parse error rather than a silent mislabel; every gate
/// whose value is not clearly passing is captured as its explicit failing or
/// unknown state.
///
/// # Errors
/// Returns a parse error when the response is for a different pull request number
/// than requested, or carries a lifecycle state GitHub does not define.
pub(crate) fn pull_request_evidence_from_response(
    identity: &PullRequestIdentity,
    response: PullRequestEvidenceResponse,
    observed_at: String,
) -> Result<PullRequestEvidenceRead, CliError> {
    let Some(node) = response
        .repository
        .and_then(|repository| repository.pull_request)
    else {
        return Ok(PullRequestEvidenceRead::missing(
            identity.clone(),
            observed_at,
        ));
    };
    if node.number != identity.number {
        return Err(CliErrorKind::workflow_parse(format!(
            "github returned pull request #{} for a #{} request",
            node.number, identity.number
        ))
        .into());
    }
    let lifecycle = lifecycle_from_state(&node.state)?;
    let gates = gates_from_node(&node);
    let identity = PullRequestIdentity {
        repository: identity.repository.clone(),
        number: identity.number,
        url: node.url.or_else(|| identity.url.clone()),
    };
    Ok(PullRequestEvidenceRead::found(PullRequestEvidence {
        identity,
        head_revision: node.head_ref_oid,
        author: node.author.map(|author| author.login),
        lifecycle,
        is_draft: node.is_draft,
        gates,
        observed_at,
    }))
}

fn gates_from_node(node: &PullRequestNode) -> PullRequestMergeGates {
    let protection = node.base_ref.as_ref().and_then(|base| base.rule.as_ref());
    PullRequestMergeGates {
        mergeability: mergeability_from_state(node.mergeable.as_deref()),
        viewer_can_update: node.viewer_can_update,
        viewer_can_merge_as_admin: node.viewer_can_merge_as_admin,
        checks: head_check_gates(node),
        required_check_names: protection.map(required_check_names).unwrap_or_default(),
        review: ReviewGate {
            decision: review_decision_from_state(node.review_decision.as_deref()),
            current_approvals: current_approvals(&node.reviews.nodes),
            required_approvals: protection
                .and_then(|rule| rule.approving_review_count)
                .unwrap_or(0),
        },
    }
}

fn mergeability_from_state(state: Option<&str>) -> Mergeability {
    match state {
        Some("MERGEABLE") => Mergeability::Mergeable,
        Some("CONFLICTING") => Mergeability::Conflicting,
        _ => Mergeability::Unknown,
    }
}

fn review_decision_from_state(state: Option<&str>) -> ReviewDecision {
    match state {
        Some("APPROVED") => ReviewDecision::Approved,
        Some("CHANGES_REQUESTED") => ReviewDecision::ChangesRequested,
        Some("REVIEW_REQUIRED") => ReviewDecision::ReviewRequired,
        _ => ReviewDecision::Unknown,
    }
}

fn head_check_gates(node: &PullRequestNode) -> Vec<CheckGate> {
    let mut gates = BTreeMap::new();
    for context in node
        .commits
        .nodes
        .iter()
        .filter_map(|commit| commit.commit.status_check_rollup.as_ref())
        .flat_map(|rollup| rollup.contexts.nodes.iter())
    {
        if let Some(gate) = context.gate() {
            gates.insert(gate.name.clone(), gate);
        }
    }
    gates.into_values().collect()
}

/// Count distinct reviewers whose most recent decisive review approves. A later
/// "changes requested" or "dismissed" from the same author drops the approval;
/// `COMMENTED` reviews are not decisive and never change the standing.
fn current_approvals(reviews: &[ReviewNode]) -> u32 {
    let mut ordered = reviews.iter().collect::<Vec<_>>();
    ordered.sort_by(|left, right| left.submitted_at.cmp(&right.submitted_at));
    let mut latest: BTreeMap<String, &str> = BTreeMap::new();
    for review in ordered {
        let Some(author) = review.author.as_ref().map(|author| author.login.as_str()) else {
            continue;
        };
        match review.state.as_str() {
            "APPROVED" | "CHANGES_REQUESTED" | "DISMISSED" => {
                latest.insert(author.to_string(), review.state.as_str());
            }
            _ => {}
        }
    }
    // The count is bounded by `reviews(first: 100)`, so it always fits; a
    // fail-closed 0 covers the unreachable overflow rather than a surprising max.
    u32::try_from(
        latest
            .values()
            .filter(|state| **state == "APPROVED")
            .count(),
    )
    .unwrap_or(0)
}

fn required_check_names(rule: &BranchProtectionRule) -> Vec<String> {
    let mut names = rule.status_check_contexts.clone();
    names.extend(rule.status_checks.iter().map(|check| check.context.clone()));
    names.sort();
    names.dedup();
    names
}

fn lifecycle_from_state(state: &str) -> Result<PullRequestLifecycle, CliError> {
    match state {
        "OPEN" => Ok(PullRequestLifecycle::Open),
        "CLOSED" => Ok(PullRequestLifecycle::Closed),
        "MERGED" => Ok(PullRequestLifecycle::Merged),
        other => Err(CliErrorKind::workflow_parse(format!(
            "unrecognized pull request state: {other}"
        ))
        .into()),
    }
}

fn evidence_descriptor() -> GitHubRequestDescriptor {
    GitHubRequestDescriptor::graphql(
        "task_board.github.pull_request_evidence",
        GitHubPriority::FreshRead,
        GitHubCachePolicy::no_store(),
    )
    .with_expected_cost(5)
}

#[derive(Debug, Deserialize)]
pub(crate) struct PullRequestEvidenceResponse {
    #[serde(default)]
    repository: Option<RepositoryNode>,
}

#[derive(Debug, Deserialize)]
struct RepositoryNode {
    #[serde(rename = "pullRequest", default)]
    pull_request: Option<PullRequestNode>,
}

#[derive(Debug, Deserialize)]
struct PullRequestNode {
    number: u64,
    #[serde(default)]
    url: Option<String>,
    #[serde(rename = "headRefOid")]
    head_ref_oid: String,
    #[serde(rename = "isDraft")]
    is_draft: bool,
    state: String,
    #[serde(default)]
    mergeable: Option<String>,
    #[serde(rename = "viewerCanUpdate", default)]
    viewer_can_update: bool,
    #[serde(rename = "viewerCanMergeAsAdmin", default)]
    viewer_can_merge_as_admin: bool,
    #[serde(rename = "reviewDecision", default)]
    review_decision: Option<String>,
    #[serde(default)]
    author: Option<ActorNode>,
    #[serde(default)]
    commits: CommitsConnection,
    #[serde(default)]
    reviews: ReviewsConnection,
    #[serde(rename = "baseRef", default)]
    base_ref: Option<BaseRefNode>,
}

#[derive(Debug, Default, Deserialize)]
struct CommitsConnection {
    #[serde(default)]
    nodes: Vec<CommitNode>,
}

#[derive(Debug, Deserialize)]
struct CommitNode {
    commit: CommitInner,
}

#[derive(Debug, Deserialize)]
struct CommitInner {
    #[serde(rename = "statusCheckRollup", default)]
    status_check_rollup: Option<StatusCheckRollup>,
}

#[derive(Debug, Deserialize)]
struct StatusCheckRollup {
    contexts: RollupContexts,
}

#[derive(Debug, Default, Deserialize)]
struct RollupContexts {
    #[serde(default)]
    nodes: Vec<RollupContext>,
}

#[derive(Debug, Deserialize)]
struct RollupContext {
    #[serde(rename = "__typename")]
    typename: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    conclusion: Option<String>,
    #[serde(rename = "detailsUrl", default)]
    details_url: Option<String>,
    #[serde(default)]
    context: Option<String>,
    #[serde(default)]
    state: Option<String>,
    #[serde(rename = "targetUrl", default)]
    target_url: Option<String>,
}

impl RollupContext {
    fn gate(&self) -> Option<CheckGate> {
        match self.typename.as_str() {
            "CheckRun" => Some(CheckGate {
                name: self.name.clone()?,
                state: check_run_state(self.status.as_deref(), self.conclusion.as_deref()),
                details_url: self.details_url.clone(),
            }),
            "StatusContext" => Some(CheckGate {
                name: self.context.clone()?,
                state: status_context_state(self.state.as_deref()),
                details_url: self.target_url.clone(),
            }),
            _ => None,
        }
    }
}

fn check_run_state(status: Option<&str>, conclusion: Option<&str>) -> CheckState {
    if status != Some("COMPLETED") {
        return CheckState::Pending;
    }
    match conclusion {
        Some("SUCCESS" | "NEUTRAL") => CheckState::Success,
        Some("SKIPPED") => CheckState::Skipped,
        // A completed check with no conclusion, or one GitHub added later, is
        // never assumed to have passed.
        _ => CheckState::Failure,
    }
}

fn status_context_state(state: Option<&str>) -> CheckState {
    match state {
        Some("SUCCESS") => CheckState::Success,
        Some("EXPECTED" | "PENDING") => CheckState::Pending,
        _ => CheckState::Failure,
    }
}

#[derive(Debug, Default, Deserialize)]
struct ReviewsConnection {
    #[serde(default)]
    nodes: Vec<ReviewNode>,
}

#[derive(Debug, Deserialize)]
struct ReviewNode {
    state: String,
    // Required: the query excludes PENDING reviews, so a submitted review always
    // carries `submittedAt`. A missing field is response drift worth failing on,
    // not a silent `None` that would reorder approvals.
    #[serde(rename = "submittedAt")]
    submitted_at: String,
    #[serde(default)]
    author: Option<ActorNode>,
}

#[derive(Debug, Deserialize)]
struct BaseRefNode {
    #[serde(rename = "branchProtectionRule", default)]
    rule: Option<BranchProtectionRule>,
}

#[derive(Debug, Deserialize)]
struct BranchProtectionRule {
    #[serde(rename = "requiredApprovingReviewCount", default)]
    approving_review_count: Option<u32>,
    #[serde(rename = "requiredStatusCheckContexts", default)]
    status_check_contexts: Vec<String>,
    #[serde(rename = "requiredStatusChecks", default)]
    status_checks: Vec<RequiredStatusCheck>,
}

#[derive(Debug, Deserialize)]
struct RequiredStatusCheck {
    context: String,
}

#[derive(Debug, Deserialize)]
struct ActorNode {
    login: String,
}
