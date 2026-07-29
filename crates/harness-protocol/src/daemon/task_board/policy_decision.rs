//! The task-board policy engine's decision result, relocated here from
//! `harness-task-board::policy`. `PolicyDecision`/`PolicyReasonCode` are pure
//! data with one pure inherent method (`is_allow`); the evaluation engine
//! that produces them (`PolicyGate`, `BuiltInPolicyGate`, `PolicyInput`, and
//! friends) stays in `harness-task-board`, since it reaches
//! `TaskBoardPriority`/`AgentMode`-bearing subject state this move has no
//! need for. `POLICY_VERSION` moves alongside because both the engine (still
//! in `harness-task-board`) and `TaskBoardOrchestratorSettings`'s own
//! `policy_version` default (now in this crate) construct decisions/settings
//! stamped with it; `harness-task-board::policy` re-exports all three names
//! at the same path.

use serde::{Deserialize, Serialize};

// Keep the historical task-board identifier for persisted decisions, replay
// history, and comparisons written before the public policy API rename.
pub const POLICY_VERSION: &str = "task-board-policy-v1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "decision", rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
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

impl PolicyDecision {
    #[must_use]
    pub const fn is_allow(&self) -> bool {
        matches!(self, Self::Allow { .. })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
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

// Existing coverage for these types stays in `harness-task-board::policy`'s
// own `#[path]` test module, exercised through the re-export below.
