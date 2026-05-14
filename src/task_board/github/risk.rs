use serde::{Deserialize, Serialize};

use super::config::GitHubProjectConfig;
use super::evidence::GitHubMergeEvidence;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitHubRiskClassification {
    pub score: u8,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reasons: Vec<GitHubRiskReason>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitHubRiskReason {
    DraftPullRequest,
    NonDefaultBaseBranch,
    UnmanagedHeadBranch,
    LargeChangeSet,
    VeryLargeChangeSet,
    ProtectedPathTouched,
}

#[must_use]
pub fn classify_github_merge_risk(
    config: &GitHubProjectConfig,
    evidence: &GitHubMergeEvidence,
) -> GitHubRiskClassification {
    let mut classifier = RiskAccumulator::default();
    classifier.add_if(
        evidence.pull_request.draft,
        25,
        GitHubRiskReason::DraftPullRequest,
    );
    classifier.add_if(
        evidence.pull_request.base_branch != config.default_branch,
        25,
        GitHubRiskReason::NonDefaultBaseBranch,
    );
    classifier.add_if(
        !evidence
            .pull_request
            .head_branch
            .starts_with(&config.branch_prefix),
        15,
        GitHubRiskReason::UnmanagedHeadBranch,
    );
    classifier.add_change_set_risk(evidence.pull_request.changed_paths.len());
    classifier.add_if(
        evidence.protected_path_touched(config),
        100,
        GitHubRiskReason::ProtectedPathTouched,
    );
    classifier.finish()
}

#[derive(Default)]
struct RiskAccumulator {
    score: u16,
    reasons: Vec<GitHubRiskReason>,
}

impl RiskAccumulator {
    fn add_if(&mut self, condition: bool, score: u16, reason: GitHubRiskReason) {
        if condition {
            self.score = self.score.saturating_add(score);
            self.reasons.push(reason);
        }
    }

    fn add_change_set_risk(&mut self, changed_paths: usize) {
        if changed_paths > 50 {
            self.score = self.score.saturating_add(60);
            self.reasons.push(GitHubRiskReason::VeryLargeChangeSet);
            return;
        }
        if changed_paths > 20 {
            self.score = self.score.saturating_add(35);
            self.reasons.push(GitHubRiskReason::LargeChangeSet);
        }
    }

    fn finish(self) -> GitHubRiskClassification {
        GitHubRiskClassification {
            score: u8::try_from(self.score.min(u16::from(u8::MAX))).unwrap_or(u8::MAX),
            reasons: self.reasons,
        }
    }
}
