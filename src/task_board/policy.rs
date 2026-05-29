use serde::{Deserialize, Serialize};

pub const TASK_BOARD_POLICY_VERSION: &str = "task-board-policy-v1";
pub const DEFAULT_AUTO_MERGE_RISK_THRESHOLD: u8 = 40;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PolicyAction {
    Sync,
    Triage,
    Plan,
    SpawnAgent,
    MutateRepo,
    PushBranch,
    OpenPr,
    SubmitReview,
    MergePr,
    DeleteWorktree,
    StopAgent,
    AccessSecret,
    DestructiveFs,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "decision", rename_all = "snake_case")]
pub enum PolicyDecision {
    Allow {
        reason_code: PolicyReasonCode,
        policy_version: String,
    },
    Deny {
        reason_code: PolicyReasonCode,
        policy_version: String,
    },
    RequireHuman {
        reason_code: PolicyReasonCode,
        policy_version: String,
    },
    RequireConsensus {
        reason_code: PolicyReasonCode,
        policy_version: String,
    },
    DryRunOnly {
        reason_code: PolicyReasonCode,
        policy_version: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PolicyReasonCode {
    DefaultAllow,
    AutoMergeAllowed,
    MissingMergeEvidence,
    ChecksNotGreen,
    BranchProtectionBlocked,
    ReviewerNotApproved,
    UnresolvedRequestedChanges,
    ProtectedPathTouched,
    RiskAboveThreshold,
    HumanRequired,
    DryRunRequired,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyEvidence {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checks_green: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch_protection_allows_merge: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reviewer_verdict_approved: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unresolved_requested_changes: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protected_path_touched: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub risk_score: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_is_open: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_is_draft: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_review_required: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_has_no_decision: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_has_merge_conflicts: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_policy_blocked: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_viewer_can_update: Option<bool>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicySubject {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_board_item_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pull_request: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub paths: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyInput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow: Option<String>,
    pub action: PolicyAction,
    #[serde(default)]
    pub subject: PolicySubject,
    #[serde(default)]
    pub evidence: PolicyEvidence,
}

pub trait PolicyGate {
    fn evaluate(&self, input: &PolicyInput) -> PolicyDecision;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BuiltInPolicyGate {
    auto_merge_risk_threshold: u8,
}

impl Default for BuiltInPolicyGate {
    fn default() -> Self {
        Self {
            auto_merge_risk_threshold: DEFAULT_AUTO_MERGE_RISK_THRESHOLD,
        }
    }
}

impl PolicyInput {
    #[must_use]
    pub fn new(action: PolicyAction) -> Self {
        Self {
            workflow: None,
            action,
            subject: PolicySubject::default(),
            evidence: PolicyEvidence::default(),
        }
    }

    #[must_use]
    pub fn with_evidence(mut self, evidence: PolicyEvidence) -> Self {
        self.evidence = evidence;
        self
    }
}

impl PolicyDecision {
    #[must_use]
    pub const fn is_allow(&self) -> bool {
        matches!(self, Self::Allow { .. })
    }
}

impl BuiltInPolicyGate {
    #[must_use]
    pub const fn new(auto_merge_risk_threshold: u8) -> Self {
        Self {
            auto_merge_risk_threshold,
        }
    }

    #[must_use]
    pub const fn auto_merge_risk_threshold(self) -> u8 {
        self.auto_merge_risk_threshold
    }

    fn decide(self, input: &PolicyInput) -> PolicyDecision {
        match input.action {
            PolicyAction::Sync
            | PolicyAction::Triage
            | PolicyAction::Plan
            | PolicyAction::SpawnAgent
            | PolicyAction::PushBranch
            | PolicyAction::OpenPr
            | PolicyAction::SubmitReview
            | PolicyAction::StopAgent => allow(PolicyReasonCode::DefaultAllow),
            PolicyAction::MutateRepo => dry_run_only(PolicyReasonCode::DryRunRequired),
            PolicyAction::DeleteWorktree
            | PolicyAction::AccessSecret
            | PolicyAction::DestructiveFs => require_human(PolicyReasonCode::HumanRequired),
            PolicyAction::MergePr => self.merge_decision(&input.evidence),
        }
    }

    fn merge_decision(self, evidence: &PolicyEvidence) -> PolicyDecision {
        let Some(checks_green) = evidence.checks_green else {
            return require_human(PolicyReasonCode::MissingMergeEvidence);
        };
        let Some(branch_protection_allows_merge) = evidence.branch_protection_allows_merge else {
            return require_human(PolicyReasonCode::MissingMergeEvidence);
        };
        let Some(reviewer_verdict_approved) = evidence.reviewer_verdict_approved else {
            return require_human(PolicyReasonCode::MissingMergeEvidence);
        };
        let Some(unresolved_requested_changes) = evidence.unresolved_requested_changes else {
            return require_human(PolicyReasonCode::MissingMergeEvidence);
        };
        let Some(protected_path_touched) = evidence.protected_path_touched else {
            return require_human(PolicyReasonCode::MissingMergeEvidence);
        };
        let Some(risk_score) = evidence.risk_score else {
            return require_human(PolicyReasonCode::MissingMergeEvidence);
        };

        if !checks_green {
            return deny(PolicyReasonCode::ChecksNotGreen);
        }
        if !branch_protection_allows_merge {
            return deny(PolicyReasonCode::BranchProtectionBlocked);
        }
        if !reviewer_verdict_approved {
            return deny(PolicyReasonCode::ReviewerNotApproved);
        }
        if unresolved_requested_changes > 0 {
            return deny(PolicyReasonCode::UnresolvedRequestedChanges);
        }
        if protected_path_touched {
            return require_consensus(PolicyReasonCode::ProtectedPathTouched);
        }
        if risk_score > self.auto_merge_risk_threshold {
            return dry_run_only(PolicyReasonCode::RiskAboveThreshold);
        }
        allow(PolicyReasonCode::AutoMergeAllowed)
    }
}

impl PolicyGate for BuiltInPolicyGate {
    fn evaluate(&self, input: &PolicyInput) -> PolicyDecision {
        self.decide(input)
    }
}

fn allow(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::Allow {
        reason_code,
        policy_version: TASK_BOARD_POLICY_VERSION.to_string(),
    }
}

fn deny(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::Deny {
        reason_code,
        policy_version: TASK_BOARD_POLICY_VERSION.to_string(),
    }
}

fn require_human(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::RequireHuman {
        reason_code,
        policy_version: TASK_BOARD_POLICY_VERSION.to_string(),
    }
}

fn require_consensus(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::RequireConsensus {
        reason_code,
        policy_version: TASK_BOARD_POLICY_VERSION.to_string(),
    }
}

fn dry_run_only(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::DryRunOnly {
        reason_code,
        policy_version: TASK_BOARD_POLICY_VERSION.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gate() -> BuiltInPolicyGate {
        BuiltInPolicyGate::new(40)
    }

    fn merge_input(evidence: PolicyEvidence) -> PolicyInput {
        PolicyInput::new(PolicyAction::MergePr).with_evidence(evidence)
    }

    fn green_merge_evidence() -> PolicyEvidence {
        PolicyEvidence {
            checks_green: Some(true),
            branch_protection_allows_merge: Some(true),
            reviewer_verdict_approved: Some(true),
            unresolved_requested_changes: Some(0),
            protected_path_touched: Some(false),
            risk_score: Some(20),
            ..PolicyEvidence::default()
        }
    }

    #[test]
    fn default_policy_allows_push_open_pr_and_spawn_agent() {
        for action in [
            PolicyAction::PushBranch,
            PolicyAction::OpenPr,
            PolicyAction::SpawnAgent,
        ] {
            let input = PolicyInput::new(action);

            assert_eq!(
                gate().evaluate(&input),
                allow(PolicyReasonCode::DefaultAllow)
            );
        }
    }

    #[test]
    fn auto_merge_allows_when_all_evidence_is_green() {
        let input = merge_input(green_merge_evidence());

        assert_eq!(
            gate().evaluate(&input),
            allow(PolicyReasonCode::AutoMergeAllowed)
        );
    }

    #[test]
    fn secrets_and_destructive_fs_require_human() {
        for action in [PolicyAction::AccessSecret, PolicyAction::DestructiveFs] {
            let input = PolicyInput::new(action);

            assert_eq!(
                gate().evaluate(&input),
                require_human(PolicyReasonCode::HumanRequired)
            );
        }
    }

    #[test]
    fn protected_merge_paths_require_consensus() {
        let mut evidence = green_merge_evidence();
        evidence.protected_path_touched = Some(true);
        let input = merge_input(evidence);

        assert_eq!(
            gate().evaluate(&input),
            require_consensus(PolicyReasonCode::ProtectedPathTouched)
        );
    }

    #[test]
    fn repo_mutation_is_dry_run_only_by_default() {
        let input = PolicyInput::new(PolicyAction::MutateRepo);

        assert_eq!(
            gate().evaluate(&input),
            dry_run_only(PolicyReasonCode::DryRunRequired)
        );
    }

    #[test]
    fn incomplete_merge_evidence_requires_human() {
        let input = merge_input(PolicyEvidence::default());

        assert_eq!(
            gate().evaluate(&input),
            require_human(PolicyReasonCode::MissingMergeEvidence)
        );
    }

    #[test]
    fn auto_merge_blocks_when_checks_are_not_green() {
        let mut evidence = green_merge_evidence();
        evidence.checks_green = Some(false);
        let input = merge_input(evidence);

        assert_eq!(
            gate().evaluate(&input),
            deny(PolicyReasonCode::ChecksNotGreen)
        );
    }

    #[test]
    fn auto_merge_blocks_when_branch_protection_rejects_merge() {
        let mut evidence = green_merge_evidence();
        evidence.branch_protection_allows_merge = Some(false);
        let input = merge_input(evidence);

        assert_eq!(
            gate().evaluate(&input),
            deny(PolicyReasonCode::BranchProtectionBlocked)
        );
    }

    #[test]
    fn auto_merge_blocks_without_approved_review_verdict() {
        let mut evidence = green_merge_evidence();
        evidence.reviewer_verdict_approved = Some(false);
        let input = merge_input(evidence);

        assert_eq!(
            gate().evaluate(&input),
            deny(PolicyReasonCode::ReviewerNotApproved)
        );
    }

    #[test]
    fn auto_merge_blocks_unresolved_requested_changes() {
        let mut evidence = green_merge_evidence();
        evidence.unresolved_requested_changes = Some(1);
        let input = merge_input(evidence);

        assert_eq!(
            gate().evaluate(&input),
            deny(PolicyReasonCode::UnresolvedRequestedChanges)
        );
    }

    #[test]
    fn auto_merge_blocks_high_risk_as_dry_run_only() {
        let mut evidence = green_merge_evidence();
        evidence.risk_score = Some(41);
        let input = merge_input(evidence);

        assert_eq!(
            gate().evaluate(&input),
            dry_run_only(PolicyReasonCode::RiskAboveThreshold)
        );
    }
}
