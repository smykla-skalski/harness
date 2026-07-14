use serde::{Deserialize, Serialize};

use super::types::{AgentMode, TaskBoardPriority};

// Keep the historical task-board identifier for persisted decisions, replay
// history, and comparisons written before the public policy API rename.
pub const POLICY_VERSION: &str = "task-board-policy-v1";
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
    // WP3 spawn-policy reason codes (additive).
    ApprovalRequired,
    ApprovalDenied,
    SpawnPolicyRequired,
    SpawnKillSwitchEngaged,
}

/// Resolution state of a durable [`ApprovalGate`](crate::task_board::policy_graph)
/// grant, injected into evaluation by the caller. `None` on the input means no
/// grant exists yet for the gate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PolicyApprovalState {
    Pending,
    Approved,
    Denied,
    Revoked,
}

/// A durable approval grant persisted by the daemon, keyed by board item,
/// action, and the canvas revision that authored the gate. Moves pending ->
/// approved | denied | revoked, then an approved grant is consumed once at
/// dispatch reservation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyApprovalGrant {
    pub id: String,
    pub board_item_id: String,
    pub action: PolicyAction,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub canvas_id: Option<String>,
    pub canvas_revision: u64,
    pub node_id: String,
    pub reason_code: PolicyReasonCode,
    pub state: PolicyApprovalState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolved_by: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolved_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub consumed_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expiry_seconds: Option<u64>,
    pub created_at: String,
    pub updated_at: String,
}

/// Caller-supplied approval-grant state for one approval-gate node. Dispatch
/// resolves durable grants for the (board item, action, revision) key and injects
/// their state here; simulation and replay supply fixture state so those paths
/// stay deterministic.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyApprovalGrantState {
    pub node_id: String,
    pub state: PolicyApprovalState,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_has_conflict_markers: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_viewer_has_active_approval: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_auto_merge_enabled: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_required_approvals_satisfied_after_viewer_approval: Option<bool>,
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
    // WP3 enrichment: task-board metadata carried into the spawn decision so the
    // recorded feed can explain a gate result and future subject-match blocks can
    // route on it. All additive and optional so pre-WP3 records still decode.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<TaskBoardPriority>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_mode: Option<AgentMode>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub target_project_types: Vec<String>,
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
    // WP3: caller-supplied evaluation timestamp. Dispatch injects `now`;
    // simulation/replay pass the scenario-supplied or recorded value so those
    // paths stay deterministic. Additive so pre-WP3 records decode as `None`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evaluated_at: Option<String>,
    // WP3: caller-supplied approval-grant states, keyed by approval-gate node id.
    // Additive so pre-WP3 records decode with an empty set.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub approvals: Vec<PolicyApprovalGrantState>,
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
            evaluated_at: None,
            approvals: Vec::new(),
        }
    }

    /// Resolved approval state for one approval-gate node, if the caller injected
    /// one. `None` means no grant exists yet for that gate.
    #[must_use]
    pub fn approval_state(&self, node_id: &str) -> Option<PolicyApprovalState> {
        self.approvals
            .iter()
            .find(|grant| grant.node_id == node_id)
            .map(|grant| grant.state)
    }

    #[must_use]
    pub fn with_evidence(mut self, evidence: PolicyEvidence) -> Self {
        self.evidence = evidence;
        self
    }

    #[must_use]
    pub fn with_subject(mut self, subject: PolicySubject) -> Self {
        self.subject = subject;
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
        policy_version: POLICY_VERSION.to_string(),
    }
}

fn deny(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::Deny {
        reason_code,
        policy_version: POLICY_VERSION.to_string(),
    }
}

fn require_human(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::RequireHuman {
        reason_code,
        policy_version: POLICY_VERSION.to_string(),
    }
}

fn require_consensus(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::RequireConsensus {
        reason_code,
        policy_version: POLICY_VERSION.to_string(),
    }
}

fn dry_run_only(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::DryRunOnly {
        reason_code,
        policy_version: POLICY_VERSION.to_string(),
    }
}

#[cfg(test)]
#[path = "policy_tests.rs"]
mod tests;
