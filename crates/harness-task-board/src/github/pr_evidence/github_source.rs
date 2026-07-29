use async_trait::async_trait;
use serde::Deserialize;
use serde_json::json;

use harness_github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_workspace::workspace::utc_now;

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
      author { login }
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
/// lifecycle state is a parse error rather than a silent mislabel.
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
        observed_at,
    }))
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
    author: Option<ActorNode>,
}

#[derive(Debug, Deserialize)]
struct ActorNode {
    login: String,
}
