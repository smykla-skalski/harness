use serde::Deserialize;
use serde_json::json;

use harness_kernel::errors::CliError;

use crate::github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
};

const DEFAULT_BRANCH_QUERY: &str = r"
query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    defaultBranchRef {
      name
    }
  }
}
";

#[derive(Debug, Deserialize)]
struct DefaultBranchResponse {
    repository: Option<DefaultBranchRepository>,
}

#[derive(Debug, Deserialize)]
struct DefaultBranchRepository {
    #[serde(rename = "defaultBranchRef")]
    default_branch_ref: Option<DefaultBranchRef>,
}

#[derive(Debug, Deserialize)]
struct DefaultBranchRef {
    name: String,
}

/// Read a repository's default branch.
///
/// A board fed from many repositories has no single answer here - `owner/alpha`
/// branches from `master` while `owner/beta` branches from `main` - so the
/// base is asked for rather than configured. Default branches change close to
/// never, hence the generous cache window.
///
/// # Errors
/// Returns provider or transport errors surfaced by the GitHub client.
pub(crate) async fn default_branch_async(
    client: &GitHubProtectedClient,
    owner: &str,
    repo: &str,
) -> Result<Option<String>, CliError> {
    let response: DefaultBranchResponse = client
        .graphql(
            GitHubRequestDescriptor::graphql(
                "task_board.github.repository_default_branch",
                GitHubPriority::Background,
                GitHubCachePolicy::read_through(
                    std::time::Duration::from_secs(6 * 60 * 60),
                    std::time::Duration::from_secs(7 * 24 * 60 * 60),
                ),
            ),
            json!({
                "query": DEFAULT_BRANCH_QUERY,
                "variables": { "owner": owner, "repo": repo },
            }),
        )
        .await
        .map(|response| response.body)?;
    Ok(response
        .repository
        .and_then(|repository| repository.default_branch_ref)
        .map(|reference| reference.name))
}
