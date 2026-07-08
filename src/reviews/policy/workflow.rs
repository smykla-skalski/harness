//! The default `reviews_auto` workflow graph.
//!
//! Reviews Auto is a policy template, not an execution fallback. This module
//! defines the authored `reviews_auto` workflow for explicit policy documents
//! that choose to include it. Runtime planners must still require an active
//! enforced policy canvas.

use crate::task_board::policy::PolicyReasonCode;
use crate::task_board::policy_graph::{
    PORT_DEFAULT, PORT_ELSE, PORT_FAIL, PORT_IN, PORT_MISSING, PORT_PASS, PORT_THEN,
    PolicyActionStep, PolicyEventWait, PolicyEvidenceCheck, PolicyEvidenceField,
    PolicyEvidencePredicate, PolicyFinishNode, PolicyGraph, PolicyGraphDecision, PolicyGraphEdge,
    PolicyGraphEdgeCondition, PolicyGraphNode, PolicyGraphNodeKind, PolicyGraphNodeLayout,
    PolicyIfThenElseCondition, PolicyWorkflowEntry,
};

use super::events::REVIEWS_CHECKS_PASSED_EVENT;

pub(crate) const REVIEWS_AUTO_WORKFLOW_ID: &str = "reviews_auto";

const ENTRY_ID: &str = "reviews-auto-entry";
const CONFLICT_GATE_ID: &str = "reviews-auto-conflict-gate";
const NOTIFY_CONFLICT_ID: &str = "reviews-auto-notify-conflicts";
const CONFLICT_NOTIFIED_ID: &str = "reviews-auto-conflicts-notified";
const ELIGIBILITY_GATE_ID: &str = "reviews-auto-eligibility-gate";
const APPROVAL_CHECK_ID: &str = "reviews-auto-approval-check";
const APPROVE_ID: &str = "reviews-auto-approve";
const AUTO_MERGE_GATE_ID: &str = "reviews-auto-auto-merge-gate";
const APPROVAL_COUNT_GATE_ID: &str = "reviews-auto-approval-count-gate";
const WAIT_ID: &str = "reviews-auto-wait";
const MERGE_ID: &str = "reviews-auto-merge";
const ALLOW_ID: &str = "reviews-auto-allow";
const BLOCKED_ID: &str = "reviews-auto-blocked";

/// Append the template `reviews_auto` workflow to `document` unless it already
/// defines a `reviews_auto` workflow (case-insensitive).
pub(crate) fn ensure_reviews_auto_workflow(document: &mut PolicyGraph) {
    let already_present = document.nodes.iter().any(|node| {
        matches!(
            &node.kind,
            PolicyGraphNodeKind::WorkflowEntry(entry)
                if entry.workflow_id.eq_ignore_ascii_case(REVIEWS_AUTO_WORKFLOW_ID)
        )
    });
    if already_present {
        return;
    }
    document.nodes.extend(reviews_auto_nodes());
    document.edges.extend(reviews_auto_edges());
    document.layout.nodes.extend(reviews_auto_layout());
}

fn node(
    id: &str,
    label: &str,
    kind: PolicyGraphNodeKind,
    input_ports: &[&str],
    output_ports: &[&str],
) -> PolicyGraphNode {
    PolicyGraphNode {
        id: id.into(),
        label: label.to_owned(),
        kind,
        automation: None,
        input_ports: input_ports.iter().map(|port| (*port).into()).collect(),
        output_ports: output_ports.iter().map(|port| (*port).into()).collect(),
        group_id: None,
    }
}

fn reviews_auto_nodes() -> Vec<PolicyGraphNode> {
    vec![
        node(
            ENTRY_ID,
            "Reviews Auto",
            PolicyGraphNodeKind::WorkflowEntry(PolicyWorkflowEntry {
                workflow_id: REVIEWS_AUTO_WORKFLOW_ID.to_owned(),
            }),
            &[],
            &[PORT_DEFAULT],
        ),
        node(
            CONFLICT_GATE_ID,
            "No conflicts",
            PolicyGraphNodeKind::EvidenceCheck {
                checks: conflict_checks(),
            },
            &[PORT_IN],
            &[PORT_PASS, PORT_FAIL, PORT_MISSING],
        ),
        node(
            NOTIFY_CONFLICT_ID,
            "Notify conflicts",
            PolicyGraphNodeKind::ActionStep(PolicyActionStep {
                action_id: "notification.emit".to_owned(),
            }),
            &[PORT_IN],
            &[PORT_DEFAULT],
        ),
        node(
            CONFLICT_NOTIFIED_ID,
            "Conflicts notified",
            PolicyGraphNodeKind::Finish(PolicyFinishNode {
                decision: PolicyGraphDecision::Allow,
                reason_code: PolicyReasonCode::HumanRequired,
            }),
            &[PORT_IN],
            &[],
        ),
        node(
            ELIGIBILITY_GATE_ID,
            "Eligible",
            PolicyGraphNodeKind::EvidenceCheck {
                checks: eligibility_checks(),
            },
            &[PORT_IN],
            &[PORT_PASS, PORT_FAIL, PORT_MISSING],
        ),
        node(
            APPROVAL_CHECK_ID,
            "Approved by me?",
            PolicyGraphNodeKind::IfThenElse(PolicyIfThenElseCondition {
                field: PolicyEvidenceField::ReviewViewerHasActiveApproval,
                predicate: PolicyEvidencePredicate::IsTrue,
            }),
            &[PORT_IN],
            &[PORT_THEN, PORT_ELSE],
        ),
        node(
            APPROVE_ID,
            "Approve",
            PolicyGraphNodeKind::ActionStep(PolicyActionStep {
                action_id: "reviews.approve".to_owned(),
            }),
            &[PORT_IN],
            &[PORT_DEFAULT],
        ),
        node(
            AUTO_MERGE_GATE_ID,
            "Auto-merge absent",
            PolicyGraphNodeKind::EvidenceCheck {
                checks: auto_merge_absent_checks(),
            },
            &[PORT_IN],
            &[PORT_PASS, PORT_FAIL, PORT_MISSING],
        ),
        node(
            APPROVAL_COUNT_GATE_ID,
            "Approvals enough",
            PolicyGraphNodeKind::EvidenceCheck {
                checks: approval_count_checks(),
            },
            &[PORT_IN],
            &[PORT_PASS, PORT_FAIL, PORT_MISSING],
        ),
        node(
            WAIT_ID,
            "Wait for checks",
            PolicyGraphNodeKind::EventWait(PolicyEventWait {
                event_key: REVIEWS_CHECKS_PASSED_EVENT.to_owned(),
            }),
            &[PORT_IN],
            &[PORT_DEFAULT],
        ),
        node(
            MERGE_ID,
            "Merge",
            PolicyGraphNodeKind::ActionStep(PolicyActionStep {
                action_id: "reviews.merge".to_owned(),
            }),
            &[PORT_IN],
            &[PORT_DEFAULT],
        ),
        node(
            ALLOW_ID,
            "Done",
            PolicyGraphNodeKind::Finish(PolicyFinishNode {
                decision: PolicyGraphDecision::Allow,
                reason_code: PolicyReasonCode::AutoMergeAllowed,
            }),
            &[PORT_IN],
            &[],
        ),
        node(
            BLOCKED_ID,
            "Needs human",
            PolicyGraphNodeKind::Finish(PolicyFinishNode {
                decision: PolicyGraphDecision::Deny,
                reason_code: PolicyReasonCode::HumanRequired,
            }),
            &[PORT_IN],
            &[],
        ),
    ]
}

fn conflict_checks() -> Vec<PolicyEvidenceCheck> {
    vec![
        evidence_check(
            PolicyEvidenceField::ReviewHasMergeConflicts,
            PolicyEvidencePredicate::IsFalse,
            PolicyReasonCode::HumanRequired,
        ),
        evidence_check(
            PolicyEvidenceField::ReviewHasConflictMarkers,
            PolicyEvidencePredicate::IsFalse,
            PolicyReasonCode::HumanRequired,
        ),
    ]
}

fn eligibility_checks() -> Vec<PolicyEvidenceCheck> {
    vec![
        evidence_check(
            PolicyEvidenceField::ReviewIsOpen,
            PolicyEvidencePredicate::IsTrue,
            PolicyReasonCode::HumanRequired,
        ),
        evidence_check(
            PolicyEvidenceField::ReviewViewerCanUpdate,
            PolicyEvidencePredicate::IsTrue,
            PolicyReasonCode::HumanRequired,
        ),
        evidence_check(
            PolicyEvidenceField::ReviewIsDraft,
            PolicyEvidencePredicate::IsFalse,
            PolicyReasonCode::HumanRequired,
        ),
        evidence_check(
            PolicyEvidenceField::ReviewPolicyBlocked,
            PolicyEvidencePredicate::IsFalse,
            PolicyReasonCode::HumanRequired,
        ),
    ]
}

fn auto_merge_absent_checks() -> Vec<PolicyEvidenceCheck> {
    vec![evidence_check(
        PolicyEvidenceField::ReviewAutoMergeEnabled,
        PolicyEvidencePredicate::IsFalse,
        PolicyReasonCode::AutoMergeAllowed,
    )]
}

fn approval_count_checks() -> Vec<PolicyEvidenceCheck> {
    vec![evidence_check(
        PolicyEvidenceField::ReviewRequiredApprovalsSatisfiedAfterViewerApproval,
        PolicyEvidencePredicate::IsTrue,
        PolicyReasonCode::ReviewerNotApproved,
    )]
}

fn evidence_check(
    field: PolicyEvidenceField,
    pass: PolicyEvidencePredicate,
    fail_reason_code: PolicyReasonCode,
) -> PolicyEvidenceCheck {
    PolicyEvidenceCheck {
        field,
        pass,
        fail_reason_code,
        missing_reason_code: PolicyReasonCode::HumanRequired,
    }
}

fn edge(
    id: &str,
    from_node: &str,
    from_port: &str,
    to_node: &str,
    condition: PolicyGraphEdgeCondition,
) -> PolicyGraphEdge {
    PolicyGraphEdge {
        id: id.into(),
        from_node: from_node.into(),
        from_port: from_port.into(),
        to_node: to_node.into(),
        to_port: PORT_IN.into(),
        label: None,
        condition,
    }
}

fn reviews_auto_edges() -> Vec<PolicyGraphEdge> {
    vec![
        edge(
            "reviews-auto-entry-conflict",
            ENTRY_ID,
            PORT_DEFAULT,
            CONFLICT_GATE_ID,
            PolicyGraphEdgeCondition::Always,
        ),
        edge(
            "reviews-auto-conflict-eligible",
            CONFLICT_GATE_ID,
            PORT_PASS,
            ELIGIBILITY_GATE_ID,
            PolicyGraphEdgeCondition::EvidencePass,
        ),
        edge(
            "reviews-auto-conflict-notify",
            CONFLICT_GATE_ID,
            PORT_FAIL,
            NOTIFY_CONFLICT_ID,
            PolicyGraphEdgeCondition::EvidenceFailure {
                reason_code: PolicyReasonCode::HumanRequired,
            },
        ),
        edge(
            "reviews-auto-conflict-missing",
            CONFLICT_GATE_ID,
            PORT_MISSING,
            BLOCKED_ID,
            PolicyGraphEdgeCondition::EvidenceMissing,
        ),
        edge(
            "reviews-auto-notify-conflict-done",
            NOTIFY_CONFLICT_ID,
            PORT_DEFAULT,
            CONFLICT_NOTIFIED_ID,
            PolicyGraphEdgeCondition::Always,
        ),
        edge(
            "reviews-auto-eligibility-approval",
            ELIGIBILITY_GATE_ID,
            PORT_PASS,
            APPROVAL_CHECK_ID,
            PolicyGraphEdgeCondition::EvidencePass,
        ),
        edge(
            "reviews-auto-eligibility-blocked",
            ELIGIBILITY_GATE_ID,
            PORT_FAIL,
            BLOCKED_ID,
            PolicyGraphEdgeCondition::EvidenceFailure {
                reason_code: PolicyReasonCode::HumanRequired,
            },
        ),
        edge(
            "reviews-auto-eligibility-missing",
            ELIGIBILITY_GATE_ID,
            PORT_MISSING,
            BLOCKED_ID,
            PolicyGraphEdgeCondition::EvidenceMissing,
        ),
        edge(
            "reviews-auto-approval-present-auto-merge",
            APPROVAL_CHECK_ID,
            PORT_THEN,
            AUTO_MERGE_GATE_ID,
            PolicyGraphEdgeCondition::ConditionTrue,
        ),
        edge(
            "reviews-auto-approval-missing-approve",
            APPROVAL_CHECK_ID,
            PORT_ELSE,
            APPROVE_ID,
            PolicyGraphEdgeCondition::ConditionFalse,
        ),
        edge(
            "reviews-auto-approve-auto-merge",
            APPROVE_ID,
            PORT_DEFAULT,
            AUTO_MERGE_GATE_ID,
            PolicyGraphEdgeCondition::Always,
        ),
        edge(
            "reviews-auto-auto-merge-absent-count",
            AUTO_MERGE_GATE_ID,
            PORT_PASS,
            APPROVAL_COUNT_GATE_ID,
            PolicyGraphEdgeCondition::EvidencePass,
        ),
        edge(
            "reviews-auto-auto-merge-present-allow",
            AUTO_MERGE_GATE_ID,
            PORT_FAIL,
            ALLOW_ID,
            PolicyGraphEdgeCondition::EvidenceFailure {
                reason_code: PolicyReasonCode::AutoMergeAllowed,
            },
        ),
        edge(
            "reviews-auto-auto-merge-missing",
            AUTO_MERGE_GATE_ID,
            PORT_MISSING,
            BLOCKED_ID,
            PolicyGraphEdgeCondition::EvidenceMissing,
        ),
        edge(
            "reviews-auto-approval-count-wait",
            APPROVAL_COUNT_GATE_ID,
            PORT_PASS,
            WAIT_ID,
            PolicyGraphEdgeCondition::EvidencePass,
        ),
        edge(
            "reviews-auto-approval-count-stop",
            APPROVAL_COUNT_GATE_ID,
            PORT_FAIL,
            ALLOW_ID,
            PolicyGraphEdgeCondition::EvidenceFailure {
                reason_code: PolicyReasonCode::ReviewerNotApproved,
            },
        ),
        edge(
            "reviews-auto-approval-count-missing",
            APPROVAL_COUNT_GATE_ID,
            PORT_MISSING,
            BLOCKED_ID,
            PolicyGraphEdgeCondition::EvidenceMissing,
        ),
        edge(
            "reviews-auto-wait-merge",
            WAIT_ID,
            PORT_DEFAULT,
            MERGE_ID,
            PolicyGraphEdgeCondition::Always,
        ),
        edge(
            "reviews-auto-merge-allow",
            MERGE_ID,
            PORT_DEFAULT,
            ALLOW_ID,
            PolicyGraphEdgeCondition::Always,
        ),
    ]
}

fn reviews_auto_layout() -> Vec<PolicyGraphNodeLayout> {
    // Placed below the seeded gate graph so the two sub-graphs never overlap
    // if the merged document is ever rendered on the canvas.
    [
        ENTRY_ID,
        CONFLICT_GATE_ID,
        NOTIFY_CONFLICT_ID,
        CONFLICT_NOTIFIED_ID,
        ELIGIBILITY_GATE_ID,
        APPROVAL_CHECK_ID,
        APPROVE_ID,
        AUTO_MERGE_GATE_ID,
        APPROVAL_COUNT_GATE_ID,
        WAIT_ID,
        MERGE_ID,
        ALLOW_ID,
        BLOCKED_ID,
    ]
    .iter()
    .enumerate()
    .map(|(index, id)| PolicyGraphNodeLayout {
        node_id: (*id).into(),
        x: 80 + i32::try_from(index).unwrap_or(0) * 220,
        y: 1400,
        source: None,
    })
    .collect()
}
