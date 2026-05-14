use std::path::Path;

use async_trait::async_trait;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::policy::PolicyInput;

mod client;
mod config;
mod evidence;
mod publication;
mod risk;

pub use client::{GitHubApiAutomationClient, GitHubCreatePullRequest, GitHubPullRequestHandle};
pub use config::{
    GitHubAutomation, GitHubAutomationLabels, GitHubAutomationToggles, GitHubMergeMethod,
    GitHubProjectConfig, ProtectedPathRule,
};
pub use evidence::{
    GitHubBranchProtectionEvidence, GitHubCheckConclusion, GitHubCheckEvidence, GitHubCheckStatus,
    GitHubMergeEvidence, GitHubPullRequestEvidence, GitHubReviewEvidence, GitHubReviewState,
};
pub use publication::GitHubBranchState;
pub use risk::{GitHubRiskClassification, GitHubRiskReason, classify_github_merge_risk};

#[async_trait]
pub trait GitHubAutomationClient: Send + Sync {
    /// Load the remote state for one managed branch.
    ///
    /// # Errors
    /// Returns provider or transport errors surfaced by the implementation.
    async fn get_branch_state(
        &self,
        _config: &GitHubProjectConfig,
        _branch: &str,
    ) -> Result<Option<GitHubBranchState>, CliError> {
        Err(CliError::from(CliErrorKind::workflow_io(
            "task-board github get_branch_state is unsupported",
        )))
    }

    /// Publish the committed HEAD snapshot from `worktree` onto `branch`.
    ///
    /// # Errors
    /// Returns provider or transport errors surfaced by the implementation.
    async fn publish_branch_from_worktree(
        &self,
        _config: &GitHubProjectConfig,
        _worktree: &Path,
        _branch: &str,
    ) -> Result<(), CliError> {
        Err(CliError::from(CliErrorKind::workflow_io(
            "task-board github publish_branch_from_worktree is unsupported",
        )))
    }

    /// Load merge-policy evidence for one pull request.
    ///
    /// # Errors
    /// Returns provider or transport errors surfaced by the implementation.
    async fn pull_request_merge_evidence(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
    ) -> Result<GitHubMergeEvidence, CliError>;

    /// Load current pull-request metadata.
    ///
    /// # Errors
    /// Returns provider or transport errors surfaced by the implementation.
    async fn get_pull_request(
        &self,
        _config: &GitHubProjectConfig,
        _pull_request_number: u64,
    ) -> Result<GitHubPullRequestHandle, CliError> {
        Err(CliError::from(CliErrorKind::workflow_io(
            "task-board github get_pull_request is unsupported",
        )))
    }

    /// Find an existing open pull request for a branch or create one when absent.
    ///
    /// # Errors
    /// Returns provider or transport errors surfaced by the implementation.
    async fn ensure_pull_request(
        &self,
        _config: &GitHubProjectConfig,
        _request: &GitHubCreatePullRequest,
    ) -> Result<GitHubPullRequestHandle, CliError> {
        Err(CliError::from(CliErrorKind::workflow_io(
            "task-board github ensure_pull_request is unsupported",
        )))
    }

    /// Transition a draft pull request into ready-for-review state.
    ///
    /// # Errors
    /// Returns provider or transport errors surfaced by the implementation.
    async fn ready_pull_request_for_review(
        &self,
        _config: &GitHubProjectConfig,
        _pull_request_number: u64,
    ) -> Result<GitHubPullRequestHandle, CliError> {
        Err(CliError::from(CliErrorKind::workflow_io(
            "task-board github ready_pull_request_for_review is unsupported",
        )))
    }

    /// Sync the managed GitHub labels for one pull request.
    ///
    /// # Errors
    /// Returns provider or transport errors surfaced by the implementation.
    async fn sync_pull_request_labels(
        &self,
        _config: &GitHubProjectConfig,
        _pull_request_number: u64,
        _managed_labels: &[String],
        _desired_labels: &[String],
    ) -> Result<(), CliError> {
        Err(CliError::from(CliErrorKind::workflow_io(
            "task-board github sync_pull_request_labels is unsupported",
        )))
    }

    /// Merge one pull request using the configured merge method.
    ///
    /// # Errors
    /// Returns provider or transport errors surfaced by the implementation.
    async fn merge_pull_request(
        &self,
        _config: &GitHubProjectConfig,
        _pull_request_number: u64,
        _method: GitHubMergeMethod,
        _head_sha: Option<&str>,
    ) -> Result<(), CliError> {
        Err(CliError::from(CliErrorKind::workflow_io(
            "task-board github merge_pull_request is unsupported",
        )))
    }
}

#[must_use]
pub fn build_auto_merge_policy_input(
    config: &GitHubProjectConfig,
    evidence: &GitHubMergeEvidence,
) -> PolicyInput {
    evidence.auto_merge_policy_input(config)
}

#[cfg(test)]
mod tests;
