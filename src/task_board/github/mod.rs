use async_trait::async_trait;

use crate::errors::CliError;
use crate::task_board::policy::PolicyInput;

mod config;
mod evidence;
mod risk;

pub use config::{
    GitHubAutomation, GitHubAutomationLabels, GitHubAutomationToggles, GitHubMergeMethod,
    GitHubProjectConfig, ProtectedPathRule,
};
pub use evidence::{
    GitHubBranchProtectionEvidence, GitHubCheckConclusion, GitHubCheckEvidence, GitHubCheckStatus,
    GitHubMergeEvidence, GitHubPullRequestEvidence, GitHubReviewEvidence, GitHubReviewState,
};
pub use risk::{GitHubRiskClassification, GitHubRiskReason, classify_github_merge_risk};

#[async_trait]
pub trait GitHubAutomationClient: Send + Sync {
    /// Load merge-policy evidence for one pull request.
    ///
    /// # Errors
    /// Returns provider or transport errors surfaced by the implementation.
    async fn pull_request_merge_evidence(
        &self,
        config: &GitHubProjectConfig,
        pull_request_number: u64,
    ) -> Result<GitHubMergeEvidence, CliError>;
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
