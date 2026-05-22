use std::path::Path;
use std::sync::OnceLock;
use std::time::Duration;

use async_trait::async_trait;
use octocrab::models;
use octocrab::params;

const GITHUB_HTTP_CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const GITHUB_HTTP_READ_TIMEOUT: Duration = Duration::from_secs(60);
use rustls::crypto::ring::default_provider;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::github_api_errors;

use super::GitHubAutomationClient;
use super::config::{GitHubMergeMethod, GitHubProjectConfig};
use super::evidence::GitHubMergeEvidence;
use super::evidence_api::pull_request_merge_evidence;
use super::publication::{
    GitHubBranchState, branch_state_async, publish_branch_from_worktree_async,
};

static RUSTLS_PROVIDER: OnceLock<()> = OnceLock::new();

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
    client: octocrab::Octocrab,
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
        ensure_rustls_provider();
        let client = octocrab::Octocrab::builder()
            .personal_token(token.to_string())
            .set_connect_timeout(Some(GITHUB_HTTP_CONNECT_TIMEOUT))
            .set_read_timeout(Some(GITHUB_HTTP_READ_TIMEOUT))
            .build()
            .map_err(client_error)?;
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
        let pulls = self
            .client
            .pulls(config.owner.as_str(), config.repo.as_str());
        if let Some(existing) =
            super::client_graphql::open_pull_request_for_branch(&self.client, config, request)
                .await?
        {
            return Ok(existing);
        }
        let mut builder = pulls
            .create(
                request.title.clone(),
                request.head_branch.clone(),
                request.base_branch.clone(),
            )
            .draft(request.draft);
        if let Some(body) = request.body.as_deref() {
            builder = builder.body(body);
        }
        builder
            .send()
            .await
            .map(|pull_request| handle_from_pull_request(&pull_request))
            .map_err(operation_error)
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
        let _: serde_json::Value = self
            .client
            .post(route, None::<&()>)
            .await
            .map_err(operation_error)?;
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
            .pulls(config.owner.as_str(), config.repo.as_str())
            .request_reviews(
                pull_request_number,
                reviewers.to_vec(),
                team_reviewers.to_vec(),
            )
            .await
            .map(|_| ())
            .map_err(operation_error)
    }

    async fn sync_pull_request_labels(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
        managed_labels: &[String],
        desired_labels: &[String],
    ) -> Result<(), CliError> {
        let issues = self
            .client
            .issues(config.owner.as_str(), config.repo.as_str());
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
        issues
            .replace_all_labels(pull_request_number, &labels)
            .await
            .map_err(operation_error)?;
        Ok(())
    }

    async fn merge_pull_request(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
        method: GitHubMergeMethod,
        head_sha: Option<&str>,
    ) -> Result<(), CliError> {
        let pulls = self
            .client
            .pulls(config.owner.as_str(), config.repo.as_str());
        let mut builder = pulls.merge(pull_request_number).method(match method {
            GitHubMergeMethod::Squash => params::pulls::MergeMethod::Squash,
            GitHubMergeMethod::Merge => params::pulls::MergeMethod::Merge,
            GitHubMergeMethod::Rebase => params::pulls::MergeMethod::Rebase,
        });
        if let Some(head_sha) = head_sha {
            builder = builder.sha(head_sha.to_string());
        }
        let response = builder.send().await.map_err(operation_error)?;
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

fn ensure_rustls_provider() {
    RUSTLS_PROVIDER.get_or_init(|| {
        let _ = default_provider().install_default();
    });
}

fn handle_from_pull_request(pull_request: &models::pulls::PullRequest) -> GitHubPullRequestHandle {
    build_pull_request_handle(
        pull_request.number,
        pull_request.html_url.to_string(),
        pull_request.draft.unwrap_or(false),
        pull_request.merged,
        pull_request.head.sha.clone(),
        pull_request
            .requested_reviewers
            .iter()
            .map(|reviewer| reviewer.login.clone())
            .collect(),
        pull_request
            .requested_teams
            .iter()
            .map(|team| team.slug.clone())
            .collect(),
    )
}

#[cfg(test)]
fn handle_from_simple_pull_request(
    pull_request: &models::pulls::SimplePullRequest,
) -> GitHubPullRequestHandle {
    build_pull_request_handle(
        pull_request.number,
        pull_request.html_url.to_string(),
        pull_request.draft.unwrap_or(false),
        pull_request.merged_at.is_some(),
        pull_request.head.sha.clone(),
        pull_request
            .requested_reviewers
            .iter()
            .map(|reviewer| reviewer.login.clone())
            .collect(),
        pull_request
            .requested_teams
            .iter()
            .map(|team| team.slug.clone())
            .collect(),
    )
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

fn client_error(error: octocrab::Error) -> CliError {
    github_api_errors::client_error("create task-board github automation client", error)
}

fn operation_error(error: octocrab::Error) -> CliError {
    github_api_errors::operation_error("task-board github automation failed", error)
}

fn pull_request_not_found(config: &GitHubProjectConfig, pull_request_number: u64) -> CliError {
    CliErrorKind::workflow_io(format!(
        "task-board github pull request not found: {}/{}#{}",
        config.owner, config.repo, pull_request_number
    ))
    .into()
}

#[cfg(test)]
mod tests;
