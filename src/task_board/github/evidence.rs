use serde::{Deserialize, Serialize};

use super::config::GitHubProjectConfig;
use super::risk::classify_github_merge_risk;
use crate::task_board::policy::{PolicyAction, PolicyEvidence, PolicyInput, PolicySubject};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitHubMergeEvidence {
    pub pull_request: GitHubPullRequestEvidence,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub checks: Vec<GitHubCheckEvidence>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reviews: Vec<GitHubReviewEvidence>,
    pub branch_protection: GitHubBranchProtectionEvidence,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitHubPullRequestEvidence {
    pub number: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub html_url: Option<String>,
    pub base_branch: String,
    pub head_branch: String,
    pub draft: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub changed_paths: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitHubCheckEvidence {
    pub name: String,
    pub status: GitHubCheckStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conclusion: Option<GitHubCheckConclusion>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitHubCheckStatus {
    Queued,
    InProgress,
    Completed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitHubCheckConclusion {
    Success,
    Failure,
    Neutral,
    Cancelled,
    Skipped,
    TimedOut,
    ActionRequired,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitHubReviewEvidence {
    pub reviewer: String,
    pub state: GitHubReviewState,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub unresolved_requested_changes: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitHubReviewState {
    Approved,
    ChangesRequested,
    Commented,
    Dismissed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitHubBranchProtectionEvidence {
    pub enabled: bool,
    pub merge_allowed: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub required_checks: Vec<String>,
}

impl GitHubMergeEvidence {
    #[must_use]
    pub fn auto_merge_policy_input(&self, config: &GitHubProjectConfig) -> PolicyInput {
        PolicyInput {
            workflow: None,
            action: PolicyAction::MergePr,
            subject: PolicySubject {
                repository: Some(config.repository_slug()),
                branch: Some(self.pull_request.head_branch.clone()),
                pull_request: Some(self.pull_request.number.to_string()),
                paths: self.pull_request.changed_paths.clone(),
                ..PolicySubject::default()
            },
            evidence: self.policy_evidence(config),
        }
    }

    #[must_use]
    pub fn policy_evidence(&self, config: &GitHubProjectConfig) -> PolicyEvidence {
        let risk = classify_github_merge_risk(config, self);
        PolicyEvidence {
            checks_green: Some(self.checks_green()),
            branch_protection_allows_merge: Some(self.branch_protection_allows_merge()),
            reviewer_verdict_approved: Some(self.reviewer_verdict_approved()),
            unresolved_requested_changes: Some(self.unresolved_requested_changes()),
            protected_path_touched: Some(self.protected_path_touched(config)),
            risk_score: Some(risk.score),
            ..PolicyEvidence::default()
        }
    }

    #[must_use]
    pub fn checks_green(&self) -> bool {
        !self.checks.is_empty() && self.checks.iter().all(GitHubCheckEvidence::is_green)
    }

    #[must_use]
    pub fn branch_protection_allows_merge(&self) -> bool {
        self.branch_protection.enabled
            && self.branch_protection.merge_allowed
            && self.required_checks_green()
    }

    #[must_use]
    pub fn reviewer_verdict_approved(&self) -> bool {
        self.reviews
            .iter()
            .any(|review| review.state == GitHubReviewState::Approved)
            && !self
                .reviews
                .iter()
                .any(|review| review.state == GitHubReviewState::ChangesRequested)
    }

    #[must_use]
    pub fn unresolved_requested_changes(&self) -> u32 {
        self.reviews
            .iter()
            .map(|review| review.unresolved_requested_changes)
            .sum()
    }

    #[must_use]
    pub fn protected_path_touched(&self, config: &GitHubProjectConfig) -> bool {
        self.pull_request
            .changed_paths
            .iter()
            .any(|path| config.protects_path(path))
    }

    fn required_checks_green(&self) -> bool {
        self.branch_protection
            .required_checks
            .iter()
            .all(|required| self.check_named_green(required))
    }

    fn check_named_green(&self, required: &str) -> bool {
        self.checks
            .iter()
            .any(|check| check.name == required && check.is_green())
    }
}

impl GitHubCheckEvidence {
    #[must_use]
    pub fn success(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            status: GitHubCheckStatus::Completed,
            conclusion: Some(GitHubCheckConclusion::Success),
        }
    }

    #[must_use]
    pub fn failure(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            status: GitHubCheckStatus::Completed,
            conclusion: Some(GitHubCheckConclusion::Failure),
        }
    }

    #[must_use]
    pub fn is_green(&self) -> bool {
        self.status == GitHubCheckStatus::Completed
            && matches!(
                self.conclusion,
                Some(
                    GitHubCheckConclusion::Success
                        | GitHubCheckConclusion::Neutral
                        | GitHubCheckConclusion::Skipped
                )
            )
    }
}

impl GitHubReviewEvidence {
    #[must_use]
    pub fn approved(reviewer: impl Into<String>) -> Self {
        Self {
            reviewer: reviewer.into(),
            state: GitHubReviewState::Approved,
            unresolved_requested_changes: 0,
        }
    }

    #[must_use]
    pub fn changes_requested(
        reviewer: impl Into<String>,
        unresolved_requested_changes: u32,
    ) -> Self {
        Self {
            reviewer: reviewer.into(),
            state: GitHubReviewState::ChangesRequested,
            unresolved_requested_changes,
        }
    }
}

#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "serde skip_serializing_if requires a function taking `&T`"
)]
fn is_zero(value: &u32) -> bool {
    *value == 0
}
