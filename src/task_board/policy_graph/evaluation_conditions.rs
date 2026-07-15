//! Condition, evidence, predicate, and edge-matching helpers for the graph
//! evaluator. Split out of `evaluation.rs` to keep it under the source-length
//! cap.

use super::{
    PORT_DEFAULT, PolicyEvidenceCheck, PolicyEvidenceField, PolicyEvidencePredicate,
    PolicyGraphEdgeCondition, PolicyGraphNode, PolicyGraphNodeKind, PolicyIfThenElseCondition,
    PolicyReasonCode, PolicySwitchArm, PolicySwitchNode,
};
use crate::task_board::policy::PolicyInput;

pub(super) fn is_workflow_entry_node(node: &PolicyGraphNode) -> bool {
    matches!(
        node.kind,
        PolicyGraphNodeKind::Trigger { .. } | PolicyGraphNodeKind::WorkflowEntry(_)
    )
}

pub(super) fn evidence_condition(
    checks: &[PolicyEvidenceCheck],
    input: &PolicyInput,
) -> PolicyGraphEdgeCondition {
    for check in checks {
        let Some(value) = evidence_value(check.field, input) else {
            return PolicyGraphEdgeCondition::EvidenceMissing;
        };
        if !predicate_passes(check.pass, value) {
            if check.fail_reason_code == PolicyReasonCode::ProtectedPathTouched {
                return PolicyGraphEdgeCondition::EvidenceConsensus {
                    reason_code: check.fail_reason_code,
                };
            }
            return PolicyGraphEdgeCondition::EvidenceFailure {
                reason_code: check.fail_reason_code,
            };
        }
    }
    PolicyGraphEdgeCondition::EvidencePass
}

pub(super) fn if_then_else_condition(
    condition: PolicyIfThenElseCondition,
    input: &PolicyInput,
) -> PolicyGraphEdgeCondition {
    let passes =
        predicate_matches_evidence(condition.predicate, evidence_value(condition.field, input));
    if passes {
        PolicyGraphEdgeCondition::ConditionTrue
    } else {
        PolicyGraphEdgeCondition::ConditionFalse
    }
}

pub(super) fn switch_port<'a>(switch: &'a PolicySwitchNode, input: &PolicyInput) -> &'a str {
    switch
        .arms
        .iter()
        .find(|arm| switch_arm_matches(arm, input))
        .map_or(PORT_DEFAULT, |arm| arm.port.as_str())
}

fn switch_arm_matches(arm: &PolicySwitchArm, input: &PolicyInput) -> bool {
    predicate_matches_evidence(arm.predicate, evidence_value(arm.field, input))
}

pub(super) fn risk_condition(
    field: PolicyEvidenceField,
    threshold: u8,
    input: &PolicyInput,
) -> PolicyGraphEdgeCondition {
    let Some(risk_score) = risk_value(field, input) else {
        return PolicyGraphEdgeCondition::RiskMissing;
    };
    if risk_score > threshold {
        PolicyGraphEdgeCondition::RiskHigh
    } else {
        PolicyGraphEdgeCondition::RiskLowOrEqual
    }
}

fn evidence_value(field: PolicyEvidenceField, input: &PolicyInput) -> Option<u32> {
    match field {
        PolicyEvidenceField::ChecksGreen => input.evidence.checks_green.map(u32::from),
        PolicyEvidenceField::BranchProtectionAllowsMerge => {
            input.evidence.branch_protection_allows_merge.map(u32::from)
        }
        PolicyEvidenceField::ReviewerVerdictApproved => {
            input.evidence.reviewer_verdict_approved.map(u32::from)
        }
        PolicyEvidenceField::UnresolvedRequestedChanges => {
            input.evidence.unresolved_requested_changes
        }
        PolicyEvidenceField::ProtectedPathTouched => {
            input.evidence.protected_path_touched.map(u32::from)
        }
        PolicyEvidenceField::RiskScore => input.evidence.risk_score.map(u32::from),
        PolicyEvidenceField::ReviewIsOpen => input.evidence.review_is_open.map(u32::from),
        PolicyEvidenceField::ReviewIsDraft => input.evidence.review_is_draft.map(u32::from),
        PolicyEvidenceField::ReviewReviewRequired => {
            input.evidence.review_review_required.map(u32::from)
        }
        PolicyEvidenceField::ReviewHasNoDecision => {
            input.evidence.review_has_no_decision.map(u32::from)
        }
        PolicyEvidenceField::ReviewHasMergeConflicts => {
            input.evidence.review_has_merge_conflicts.map(u32::from)
        }
        PolicyEvidenceField::ReviewPolicyBlocked => {
            input.evidence.review_policy_blocked.map(u32::from)
        }
        PolicyEvidenceField::ReviewViewerCanUpdate => {
            input.evidence.review_viewer_can_update.map(u32::from)
        }
        PolicyEvidenceField::ReviewHasConflictMarkers => {
            input.evidence.review_has_conflict_markers.map(u32::from)
        }
        PolicyEvidenceField::ReviewViewerHasActiveApproval => input
            .evidence
            .review_viewer_has_active_approval
            .map(u32::from),
        PolicyEvidenceField::ReviewAutoMergeEnabled => {
            input.evidence.review_auto_merge_enabled.map(u32::from)
        }
        PolicyEvidenceField::ReviewRequiredApprovalsSatisfiedAfterViewerApproval => input
            .evidence
            .review_required_approvals_satisfied_after_viewer_approval
            .map(u32::from),
    }
}

fn risk_value(field: PolicyEvidenceField, input: &PolicyInput) -> Option<u8> {
    match field {
        PolicyEvidenceField::RiskScore => input.evidence.risk_score,
        _ => evidence_value(field, input).and_then(|value| u8::try_from(value).ok()),
    }
}

pub(in crate::task_board::policy_graph) const fn predicate_passes(
    predicate: PolicyEvidencePredicate,
    value: u32,
) -> bool {
    match predicate {
        PolicyEvidencePredicate::IsTrue => value == 1,
        PolicyEvidencePredicate::IsFalse | PolicyEvidencePredicate::IsZero => value == 0,
        PolicyEvidencePredicate::IsPositive => value > 0,
        PolicyEvidencePredicate::IsPresent => true,
        PolicyEvidencePredicate::IsMissing => false,
    }
}

const fn predicate_matches_evidence(
    predicate: PolicyEvidencePredicate,
    value: Option<u32>,
) -> bool {
    match value {
        Some(value) => predicate_passes(predicate, value),
        None => matches!(predicate, PolicyEvidencePredicate::IsMissing),
    }
}

pub(super) fn edge_condition_matches(
    candidate: &PolicyGraphEdgeCondition,
    target: &PolicyGraphEdgeCondition,
) -> bool {
    match (candidate, target) {
        (PolicyGraphEdgeCondition::Always, PolicyGraphEdgeCondition::Always)
        | (PolicyGraphEdgeCondition::ConditionTrue, PolicyGraphEdgeCondition::ConditionTrue)
        | (PolicyGraphEdgeCondition::ConditionFalse, PolicyGraphEdgeCondition::ConditionFalse)
        | (PolicyGraphEdgeCondition::EvidencePass, PolicyGraphEdgeCondition::EvidencePass)
        | (PolicyGraphEdgeCondition::EvidenceMissing, PolicyGraphEdgeCondition::EvidenceMissing)
        | (PolicyGraphEdgeCondition::RiskHigh, PolicyGraphEdgeCondition::RiskHigh)
        | (PolicyGraphEdgeCondition::RiskLowOrEqual, PolicyGraphEdgeCondition::RiskLowOrEqual)
        | (PolicyGraphEdgeCondition::RiskMissing, PolicyGraphEdgeCondition::RiskMissing) => true,
        (
            PolicyGraphEdgeCondition::EvidenceFailure {
                reason_code: candidate,
            },
            PolicyGraphEdgeCondition::EvidenceFailure {
                reason_code: target,
            },
        )
        | (
            PolicyGraphEdgeCondition::EvidenceConsensus {
                reason_code: candidate,
            },
            PolicyGraphEdgeCondition::EvidenceConsensus {
                reason_code: target,
            },
        ) => candidate == target,
        _ => false,
    }
}
