use serde_json::json;

use crate::errors::CliError;
use crate::github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
};

use super::{GraphqlPullRequestHandle, PULL_REQUEST_HANDLE_QUERY, PullRequestHandleResponse};
use crate::task_board::github::{GitHubProjectConfig, GitHubPullRequestHandle};

pub(in crate::task_board::github) async fn pull_request_handle_fresh(
    client: &GitHubProtectedClient,
    config: &GitHubProjectConfig,
    pull_request_number: u64,
) -> Result<Option<GitHubPullRequestHandle>, CliError> {
    let response: PullRequestHandleResponse = client
        .graphql(
            fresh_descriptor("task_board.github.pull_request_handle_fresh"),
            json!({
            "query": PULL_REQUEST_HANDLE_QUERY,
            "variables": {
                "owner": config.owner.as_str(),
                "repo": config.repo.as_str(),
                "number": pull_request_number,
            },
            }),
        )
        .await
        .map(|response| response.body)?;
    Ok(response
        .pull_request()
        .map(GraphqlPullRequestHandle::into_handle))
}

fn fresh_descriptor(operation: &str) -> GitHubRequestDescriptor {
    GitHubRequestDescriptor::graphql(
        operation,
        GitHubPriority::FreshRead,
        GitHubCachePolicy::no_store(),
    )
    .with_expected_cost(5)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_pull_request_reads_are_never_cached() {
        assert_eq!(
            fresh_descriptor("test").cache_policy,
            GitHubCachePolicy::no_store()
        );
    }
}
