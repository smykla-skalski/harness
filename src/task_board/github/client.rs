use std::path::Path;

use async_trait::async_trait;
use reqwest::Method;
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
};

use super::GitHubAutomationClient;
use super::config::{GitHubMergeMethod, GitHubProjectConfig};
use super::evidence::GitHubMergeEvidence;
use super::evidence_api::pull_request_merge_evidence;
use super::publication::{
    GitHubBranchState, branch_state_async, publish_branch_from_worktree_async,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitHubPullRequestHandle {
    pub number: u64,
    pub html_url: Option<String>,
    pub draft: bool,
    pub merged: bool,
    pub head_sha: String,
    pub requested_reviewers: Vec<String>,
    pub requested_team_reviewers: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitHubCreatePullRequest {
    pub title: String,
    pub body: Option<String>,
    pub head_branch: String,
    pub base_branch: String,
    pub draft: bool,
}

#[derive(Clone)]
pub struct GitHubApiAutomationClient {
    client: GitHubProtectedClient,
    token: String,
}

impl GitHubApiAutomationClient {
    /// Build a GitHub automation client from a token.
    ///
    /// # Errors
    /// Returns an error when the token is empty or the API client cannot be built.
    pub fn new(token: impl Into<String>) -> Result<Self, CliError> {
        let token = token.into();
        let token = token.trim();
        if token.is_empty() {
            return Err(CliErrorKind::workflow_io("task-board github token missing").into());
        }
        let client = GitHubProtectedClient::new(token)?;
        Ok(Self {
            client,
            token: token.to_string(),
        })
    }
}

#[async_trait]
impl GitHubAutomationClient for GitHubApiAutomationClient {
    async fn get_branch_state(
        &self,
        config: &GitHubProjectConfig,
        branch: &str,
    ) -> Result<Option<GitHubBranchState>, CliError> {
        branch_state_async(&self.client, config, branch).await
    }

    async fn publish_branch_from_worktree(
        &self,
        config: &GitHubProjectConfig,
        worktree: &Path,
        branch: &str,
    ) -> Result<(), CliError> {
        publish_branch_from_worktree_async(&self.client, config, worktree, branch, &self.token)
            .await
    }

    async fn pull_request_merge_evidence(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
    ) -> Result<GitHubMergeEvidence, CliError> {
        pull_request_merge_evidence(&self.client, config, pull_request_number).await
    }

    async fn get_pull_request(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
    ) -> Result<GitHubPullRequestHandle, CliError> {
        super::client_graphql::pull_request_handle(&self.client, config, pull_request_number)
            .await?
            .ok_or_else(|| pull_request_not_found(config, pull_request_number))
    }

    async fn ensure_pull_request(
        &self,
        config: &GitHubProjectConfig,
        request: &GitHubCreatePullRequest,
    ) -> Result<GitHubPullRequestHandle, CliError> {
        if let Some(existing) =
            super::client_graphql::open_pull_request_for_branch(&self.client, config, request)
                .await?
        {
            return Ok(existing);
        }
        let mut body = serde_json::Map::new();
        body.insert("title".into(), json!(request.title));
        body.insert("head".into(), json!(request.head_branch));
        body.insert("base".into(), json!(request.base_branch));
        body.insert("draft".into(), json!(request.draft));
        if let Some(body_text) = request.body.as_deref() {
            body.insert("body".into(), json!(body_text));
        }
        self.client
            .rest_json(
                Method::POST,
                format!("/repos/{}/{}/pulls", config.owner, config.repo),
                Some(serde_json::Value::Object(body)),
                rest_write_descriptor("task_board.github.pull_request_create"),
            )
            .await
            .map(|response| rest_pull_request_handle(response.body))
    }

    async fn ready_pull_request_for_review(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
    ) -> Result<GitHubPullRequestHandle, CliError> {
        let route = format!(
            "/repos/{owner}/{repo}/pulls/{pull_request_number}/ready_for_review",
            owner = config.owner,
            repo = config.repo,
        );
        self.client
            .rest_empty(
                Method::POST,
                route,
                None,
                rest_write_descriptor("task_board.github.ready_for_review"),
            )
            .await?;
        self.get_pull_request(config, pull_request_number).await
    }

    async fn request_pull_request_reviewers(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
        reviewers: &[String],
        team_reviewers: &[String],
    ) -> Result<(), CliError> {
        self.client
            .rest_empty(
                Method::POST,
                format!(
                    "/repos/{}/{}/pulls/{pull_request_number}/requested_reviewers",
                    config.owner, config.repo
                ),
                Some(json!({
                    "reviewers": reviewers,
                    "team_reviewers": team_reviewers,
                })),
                rest_write_descriptor("task_board.github.request_reviewers"),
            )
            .await
    }

    async fn sync_pull_request_labels(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
        managed_labels: &[String],
        desired_labels: &[String],
    ) -> Result<(), CliError> {
        let current_labels =
            super::client_graphql::pull_request_labels(&self.client, config, pull_request_number)
                .await?;
        let managed = managed_labels
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>();
        let mut labels = current_labels
            .into_iter()
            .filter(|label| !managed.contains(&label.as_str()))
            .collect::<Vec<_>>();
        labels.extend(desired_labels.iter().cloned());
        labels.sort();
        labels.dedup();
        self.client
            .rest_empty(
                Method::PUT,
                format!(
                    "/repos/{}/{}/issues/{pull_request_number}/labels",
                    config.owner, config.repo
                ),
                Some(json!({ "labels": labels })),
                rest_write_descriptor("task_board.github.replace_labels"),
            )
            .await?;
        Ok(())
    }

    async fn merge_pull_request(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
        method: GitHubMergeMethod,
        head_sha: Option<&str>,
    ) -> Result<(), CliError> {
        let mut body = serde_json::Map::new();
        body.insert("merge_method".into(), json!(github_merge_method(method)));
        if let Some(head_sha) = head_sha {
            body.insert("sha".into(), json!(head_sha));
        }
        let response: GitHubMergeResponse = self
            .client
            .rest_json(
                Method::PUT,
                format!(
                    "/repos/{}/{}/pulls/{pull_request_number}/merge",
                    config.owner, config.repo
                ),
                Some(serde_json::Value::Object(body)),
                rest_write_descriptor("task_board.github.merge_pull_request"),
            )
            .await
            .map(|response| response.body)?;
        if response.merged {
            return Ok(());
        }
        Err(CliErrorKind::workflow_io(format!(
            "task-board github merge rejected: {}",
            response
                .message
                .unwrap_or_else(|| "no merge rejection message returned".to_string())
        ))
        .into())
    }
}

fn build_pull_request_handle(
    number: u64,
    html_url: String,
    draft: bool,
    merged: bool,
    head_sha: String,
    requested_reviewers: Vec<String>,
    requested_team_reviewers: Vec<String>,
) -> GitHubPullRequestHandle {
    GitHubPullRequestHandle {
        number,
        html_url: Some(html_url),
        draft,
        merged,
        head_sha,
        requested_reviewers,
        requested_team_reviewers,
    }
}

fn pull_request_not_found(config: &GitHubProjectConfig, pull_request_number: u64) -> CliError {
    CliErrorKind::workflow_io(format!(
        "task-board github pull request not found: {}/{}#{}",
        config.owner, config.repo, pull_request_number
    ))
    .into()
}

#[derive(Debug, Deserialize)]
struct RestPullRequestResponse {
    number: u64,
    html_url: String,
    draft: Option<bool>,
    merged: Option<bool>,
    head: RestPullRequestBranch,
    #[serde(default)]
    requested_reviewers: Vec<RestPullRequestUser>,
    #[serde(default)]
    requested_teams: Vec<RestPullRequestTeam>,
}

#[derive(Debug, Deserialize)]
struct RestPullRequestBranch {
    sha: String,
}

#[derive(Debug, Deserialize)]
struct RestPullRequestUser {
    login: String,
}

#[derive(Debug, Deserialize)]
struct RestPullRequestTeam {
    slug: String,
}

#[derive(Debug, Deserialize)]
struct GitHubMergeResponse {
    merged: bool,
    message: Option<String>,
}

fn rest_pull_request_handle(pull_request: RestPullRequestResponse) -> GitHubPullRequestHandle {
    build_pull_request_handle(
        pull_request.number,
        pull_request.html_url,
        pull_request.draft.unwrap_or(false),
        pull_request.merged.unwrap_or(false),
        pull_request.head.sha,
        pull_request
            .requested_reviewers
            .into_iter()
            .map(|reviewer| reviewer.login)
            .collect(),
        pull_request
            .requested_teams
            .into_iter()
            .map(|team| team.slug)
            .collect(),
    )
}

fn github_merge_method(method: GitHubMergeMethod) -> &'static str {
    match method {
        GitHubMergeMethod::Squash => "squash",
        GitHubMergeMethod::Merge => "merge",
        GitHubMergeMethod::Rebase => "rebase",
    }
}

fn rest_write_descriptor(operation: &str) -> GitHubRequestDescriptor {
    GitHubRequestDescriptor::rest_core(
        operation,
        GitHubPriority::Mutation,
        GitHubCachePolicy::no_store(),
    )
}

#[cfg(test)]
mod tests;
