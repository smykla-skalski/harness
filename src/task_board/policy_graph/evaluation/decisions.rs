use super::super::{PolicyGraphDecision, PolicyReasonCode};
use crate::task_board::policy::{POLICY_VERSION, PolicyDecision};

pub(super) fn supervisor_decision(
    decision: PolicyGraphDecision,
    reason_code: PolicyReasonCode,
) -> PolicyDecision {
    match decision {
        PolicyGraphDecision::Allow => allow(reason_code),
        PolicyGraphDecision::Deny => deny(reason_code),
    }
}

pub(super) fn allow(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::Allow {
        reason_code,
        policy_version: POLICY_VERSION.to_string(),
    }
}

pub(super) fn deny(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::Deny {
        reason_code,
        policy_version: POLICY_VERSION.to_string(),
    }
}

pub(super) fn require_human(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::RequireHuman {
        reason_code,
        policy_version: POLICY_VERSION.to_string(),
    }
}

pub(super) fn require_consensus(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::RequireConsensus {
        reason_code,
        policy_version: POLICY_VERSION.to_string(),
    }
}

pub(super) fn dry_run_only(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::DryRunOnly {
        reason_code,
        policy_version: POLICY_VERSION.to_string(),
    }
}

pub(super) fn supervisor_reason_code(reason_codes: &[PolicyReasonCode]) -> PolicyReasonCode {
    reason_codes
        .first()
        .copied()
        .unwrap_or(PolicyReasonCode::DefaultAllow)
}
