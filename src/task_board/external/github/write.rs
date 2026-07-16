use reqwest::Method;
use serde::Deserialize;

use crate::errors::CliError;
use crate::github_api::{GitHubCachePolicy, GitHubPriority, GitHubRequestDescriptor};
use crate::task_board::types::TaskBoardItem;

use super::errors::github_sync_error_with_context;
use super::{
    ExternalProvider, ExternalTask, ExternalTaskRef, GitHubRepository, GitHubSyncClient,
    github_external_id, github_issue_search_status, non_empty_body,
};

impl GitHubSyncClient {
    pub(super) async fn create_issue(
        &self,
        repository: &GitHubRepository,
        item: &TaskBoardItem,
    ) -> Result<GitHubIssueResponse, CliError> {
        let mut body = serde_json::Map::new();
        body.insert("title".into(), serde_json::json!(item.title));
        if let Some(body_text) = non_empty_body(&item.body) {
            body.insert("body".into(), serde_json::json!(body_text));
        }
        let route = format!("/repos/{}/{}/issues", repository.owner, repository.repo);
        self.client
            .rest_json(
                Method::POST,
                route,
                Some(serde_json::Value::Object(body)),
                github_write_descriptor("task_board.github.issue_create"),
            )
            .await
            .map(|response| response.body)
            .map_err(|error| {
                github_sync_error_with_context(
                    format!("creating issue in {}", repository.slug()),
                    &error,
                )
            })
    }

    pub(super) async fn patch_issue(
        &self,
        repository: &GitHubRepository,
        issue_number: u64,
        body: serde_json::Value,
    ) -> Result<GitHubIssueResponse, CliError> {
        let route = format!(
            "/repos/{}/{}/issues/{issue_number}",
            repository.owner, repository.repo
        );
        self.client
            .rest_json(
                Method::PATCH,
                route,
                Some(body),
                github_write_descriptor("task_board.github.issue_update"),
            )
            .await
            .map(|response| response.body)
            .map_err(|error| {
                github_sync_error_with_context(
                    format!("updating issue {issue_number} in {}", repository.slug()),
                    &error,
                )
            })
    }

    pub(super) async fn fetch_issue(
        &self,
        repository: &GitHubRepository,
        issue_number: u64,
    ) -> Result<GitHubIssueResponse, CliError> {
        let route = format!(
            "/repos/{}/{}/issues/{issue_number}",
            repository.owner, repository.repo
        );
        self.client
            .rest_json(
                Method::GET,
                route,
                None,
                GitHubRequestDescriptor::rest_core(
                    "task_board.github.issue_precondition",
                    GitHubPriority::FreshRead,
                    GitHubCachePolicy::no_store(),
                ),
            )
            .await
            .map(|response| response.body)
            .map_err(|error| {
                github_sync_error_with_context(
                    format!("loading issue {issue_number} in {}", repository.slug()),
                    &error,
                )
            })
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct GitHubIssueResponse {
    pub(super) number: u64,
    pub(super) html_url: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    body: Option<String>,
    #[serde(default)]
    state: String,
    #[serde(default)]
    pub(super) updated_at: Option<String>,
}

impl GitHubIssueResponse {
    pub(super) fn into_external_task(self, repository: &GitHubRepository) -> ExternalTask {
        ExternalTask {
            reference: ExternalTaskRef::new(
                ExternalProvider::GitHub,
                github_external_id(repository, self.number),
            )
            .with_url(self.html_url),
            title: self.title,
            body: self.body.unwrap_or_default(),
            status: github_issue_search_status(&self.state),
            project_id: Some(repository.slug()),
            updated_at: self.updated_at,
        }
    }
}

fn github_write_descriptor(operation: &str) -> GitHubRequestDescriptor {
    GitHubRequestDescriptor::rest_core(
        operation,
        GitHubPriority::Mutation,
        GitHubCachePolicy::no_store(),
    )
}

#[cfg(test)]
mod tests;
