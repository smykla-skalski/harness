//! The default `reviews_auto` workflow graph.
//!
//! Reviews Auto is a policy template, not an execution fallback. This module
//! defines the authored `reviews_auto` workflow (gate, approve, wait for
//! checks, merge) for explicit policy documents that choose to include it.
//! Runtime planners must still require an active enforced policy canvas.

use crate::task_board::policy::PolicyReasonCode;
use crate::task_board::policy_graph::{
    PORT_DEFAULT, PORT_FAIL, PORT_IN, PORT_MISSING, PORT_PASS, PolicyActionStep, PolicyEventWait,
    PolicyEvidenceCheck, PolicyEvidenceField, PolicyEvidencePredicate, PolicyFinishNode,
    PolicyGraph, PolicyGraphDecision, PolicyGraphEdge, PolicyGraphEdgeCondition, PolicyGraphNode,
    PolicyGraphNodeKind, PolicyGraphNodeLayout, PolicyWorkflowEntry,
};

use super::events::REVIEWS_CHECKS_PASSED_EVENT;

pub(crate) const REVIEWS_AUTO_WORKFLOW_ID: &str = "reviews_auto";

const ENTRY_ID: &str = "reviews-auto-entry";
const GATE_ID: &str = "reviews-auto-approve-gate";
const APPROVE_ID: &str = "reviews-auto-approve";
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
        id: id.to_owned(),
        label: label.to_owned(),
        kind,
        automation: None,
        input_ports: input_ports.iter().map(|port| (*port).to_owned()).collect(),
        output_ports: output_ports.iter().map(|port| (*port).to_owned()).collect(),
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
            GATE_ID,
            "Approvable",
            PolicyGraphNodeKind::EvidenceCheck {
                checks: approve_checks(),
            },
            &[PORT_IN],
            &[PORT_PASS, PORT_FAIL, PORT_MISSING],
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
            "Merged",
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

fn approve_checks() -> Vec<PolicyEvidenceCheck> {
    [
        PolicyEvidenceField::ReviewIsOpen,
        PolicyEvidenceField::ReviewViewerCanUpdate,
    ]
    .into_iter()
    .map(|field| PolicyEvidenceCheck {
        field,
        pass: PolicyEvidencePredicate::IsTrue,
        fail_reason_code: PolicyReasonCode::HumanRequired,
        missing_reason_code: PolicyReasonCode::HumanRequired,
    })
    .collect()
}

fn edge(
    id: &str,
    from_node: &str,
    from_port: &str,
    to_node: &str,
    condition: PolicyGraphEdgeCondition,
) -> PolicyGraphEdge {
    PolicyGraphEdge {
        id: id.to_owned(),
        from_node: from_node.to_owned(),
        from_port: from_port.to_owned(),
        to_node: to_node.to_owned(),
        to_port: PORT_IN.to_owned(),
        label: None,
        condition,
    }
}

fn reviews_auto_edges() -> Vec<PolicyGraphEdge> {
    vec![
        edge(
            "reviews-auto-entry-gate",
            ENTRY_ID,
            PORT_DEFAULT,
            GATE_ID,
            PolicyGraphEdgeCondition::Always,
        ),
        edge(
            "reviews-auto-gate-approve",
            GATE_ID,
            PORT_PASS,
            APPROVE_ID,
            PolicyGraphEdgeCondition::EvidencePass,
        ),
        edge(
            "reviews-auto-gate-blocked",
            GATE_ID,
            PORT_FAIL,
            BLOCKED_ID,
            PolicyGraphEdgeCondition::EvidenceFailure {
                reason_code: PolicyReasonCode::HumanRequired,
            },
        ),
        edge(
            "reviews-auto-gate-missing",
            GATE_ID,
            PORT_MISSING,
            BLOCKED_ID,
            PolicyGraphEdgeCondition::EvidenceMissing,
        ),
        edge(
            "reviews-auto-approve-wait",
            APPROVE_ID,
            PORT_DEFAULT,
            WAIT_ID,
            PolicyGraphEdgeCondition::Always,
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
        ENTRY_ID, GATE_ID, APPROVE_ID, WAIT_ID, MERGE_ID, ALLOW_ID, BLOCKED_ID,
    ]
    .iter()
    .enumerate()
    .map(|(index, id)| PolicyGraphNodeLayout {
        node_id: (*id).to_owned(),
        x: 80 + i32::try_from(index).unwrap_or(0) * 220,
        y: 1400,
        source: None,
    })
    .collect()
}
