use std::path::Path;
use std::sync::OnceLock;

use async_trait::async_trait;
use octocrab::models;
use octocrab::params;
use rustls::crypto::ring::default_provider;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};

use super::GitHubAutomationClient;
use super::config::{GitHubMergeMethod, GitHubProjectConfig};
use super::evidence::{GitHubMergeEvidence, GitHubPullRequestEvidence};
use super::evidence_api::{
    branch_protection_evidence, check_runs_for_ref, combined_status_for_sha, merge_checks,
    merge_reviews, review_thread_summary,
};
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
        let pulls = self
            .client
            .pulls(config.owner.as_str(), config.repo.as_str());
        let pull_request = pulls
            .get(pull_request_number)
            .await
            .map_err(operation_error)?;
        let files = self
            .client
            .all_pages(
                pulls
                    .list_files(pull_request_number)
                    .await
                    .map_err(operation_error)?,
            )
            .await
            .map_err(operation_error)?;
        let reviews = self
            .client
            .all_pages(
                pulls
                    .list_reviews(pull_request_number)
                    .per_page(100_u8)
                    .send()
                    .await
                    .map_err(operation_error)?,
            )
            .await
            .map_err(operation_error)?;
        let head_sha = pull_request.head.sha.clone();
        let combined_status = combined_status_for_sha(&self.client, config, &head_sha)
            .await
            .map_err(operation_error)?;
        let check_runs = check_runs_for_ref(&self.client, config, &head_sha)
            .await
            .map_err(operation_error)?;
        let branch_protection = branch_protection_evidence(&self.client, config, &pull_request)
            .await
            .map_err(operation_error)?;
        let review_threads = review_thread_summary(&self.client, config, &pull_request)
            .await
            .map_err(operation_error)?;
        Ok(GitHubMergeEvidence {
            pull_request: GitHubPullRequestEvidence {
                number: pull_request.number,
                html_url: Some(pull_request.html_url.to_string()),
                base_branch: pull_request.base.ref_field.clone(),
                head_branch: pull_request.head.ref_field.clone(),
                draft: pull_request.draft.unwrap_or(false),
                changed_paths: files.into_iter().map(|entry| entry.filename).collect(),
            },
            checks: merge_checks(combined_status.statuses, check_runs),
            reviews: merge_reviews(reviews, &review_threads),
            branch_protection,
        })
    }

    async fn get_pull_request(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
    ) -> Result<GitHubPullRequestHandle, CliError> {
        self.client
            .pulls(config.owner.as_str(), config.repo.as_str())
            .get(pull_request_number)
            .await
            .map(|pull_request| handle_from_pull_request(&pull_request))
            .map_err(operation_error)
    }

    async fn ensure_pull_request(
        &self,
        config: &GitHubProjectConfig,
        request: &GitHubCreatePullRequest,
    ) -> Result<GitHubPullRequestHandle, CliError> {
        let pulls = self
            .client
            .pulls(config.owner.as_str(), config.repo.as_str());
        let existing = self
            .client
            .all_pages(
                pulls
                    .list()
                    .state(params::State::Open)
                    .head(format!("{}:{}", config.owner, request.head_branch))
                    .per_page(100_u8)
                    .send()
                    .await
                    .map_err(operation_error)?,
            )
            .await
            .map_err(operation_error)?;
        if let Some(existing) = existing.into_iter().next() {
            return Ok(handle_from_pull_request(&existing));
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
        let current_labels = self
            .client
            .all_pages(
                issues
                    .list_labels_for_issue(pull_request_number)
                    .per_page(100_u8)
                    .send()
                    .await
                    .map_err(operation_error)?,
            )
            .await
            .map_err(operation_error)?;
        let managed = managed_labels
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>();
        let mut labels = current_labels
            .into_iter()
            .map(|label| label.name)
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
    GitHubPullRequestHandle {
        number: pull_request.number,
        html_url: Some(pull_request.html_url.to_string()),
        draft: pull_request.draft.unwrap_or(false),
        merged: pull_request.merged,
        head_sha: pull_request.head.sha.clone(),
    }
}

fn client_error(error: octocrab::Error) -> CliError {
    CliError::new(CliErrorKind::workflow_io(format!(
        "create task-board github automation client: {error}"
    )))
    .with_source(error)
}

fn operation_error(error: octocrab::Error) -> CliError {
    CliError::new(CliErrorKind::workflow_io(format!(
        "task-board github automation failed: {error}"
    )))
    .with_source(error)
}
