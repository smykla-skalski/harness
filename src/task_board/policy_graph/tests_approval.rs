use super::*;
use crate::task_board::policy::{PolicyApprovalGrantState, PolicyApprovalState};

/// Build the manual spawn policy `ActionGate[spawn_agent] -> ApprovalGate ->
/// Finish(allow)`. When `approved_edge` is false the approval gate's `approved`
/// output is left dangling so the spawn route has no terminal.
fn approval_spawn_graph(approved_edge: bool) -> PolicyGraph {
    let mut edges = vec![json!({
        "id": "edge-gate-to-approval",
        "from_node": "gate-spawn",
        "from_port": "match",
        "to_node": "approve-spawn",
        "to_port": "in",
        "condition": { "condition": "action_in", "actions": ["spawn_agent"] }
    })];
    if approved_edge {
        edges.push(json!({
            "id": "edge-approval-to-finish",
            "from_node": "approve-spawn",
            "from_port": "approved",
            "to_node": "finish-allow",
            "to_port": "in",
            "condition": { "condition": "always" }
        }));
    }
    let graph = json!({
        "schema_version": 2,
        "revision": 1,
        "mode": "enforced",
        "nodes": [
            {
                "id": "gate-spawn",
                "label": "Spawn gate",
                "kind": { "kind": "action_gate", "actions": ["spawn_agent"] },
                "input_ports": ["in"],
                "output_ports": ["match", "default"]
            },
            {
                "id": "approve-spawn",
                "label": "Approve spawn",
                "kind": {
                    "kind": "approval_gate",
                    "reason_code": "approval_required"
                },
                "input_ports": ["in"],
                "output_ports": ["approved"]
            },
            {
                "id": "finish-allow",
                "label": "Allow",
                "kind": {
                    "kind": "finish",
                    "decision": "allow",
                    "reason_code": "default_allow"
                },
                "input_ports": ["in"],
                "output_ports": []
            }
        ],
        "edges": edges,
        "groups": [],
        "layout": {}
    });
    serde_json::from_value(graph).expect("approval spawn graph deserializes")
}

fn spawn_input(approvals: Vec<PolicyApprovalGrantState>) -> PolicyInput {
    let mut input = PolicyInput::new(PolicyAction::SpawnAgent);
    input.approvals = approvals;
    input
}

fn grant(state: PolicyApprovalState) -> Vec<PolicyApprovalGrantState> {
    vec![PolicyApprovalGrantState {
        node_id: "approve-spawn".to_owned(),
        state,
    }]
}

#[test]
fn approval_gate_without_grant_requires_human_and_requests_a_grant() {
    let graph = approval_spawn_graph(true);

    let result = graph.simulate(&spawn_input(Vec::new()));

    assert!(matches!(
        result.decision,
        PolicyDecision::RequireHuman {
            reason_code: PolicyReasonCode::ApprovalRequired,
            ..
        }
    ));
    assert_eq!(result.approval_requests.len(), 1);
    assert_eq!(result.approval_requests[0].node_id, "approve-spawn");
    assert_eq!(
        result.approval_requests[0].reason_code,
        PolicyReasonCode::ApprovalRequired
    );
}

#[test]
fn approval_gate_pending_grant_requires_human_without_new_request() {
    let graph = approval_spawn_graph(true);

    let result = graph.simulate(&spawn_input(grant(PolicyApprovalState::Pending)));

    assert!(matches!(
        result.decision,
        PolicyDecision::RequireHuman { .. }
    ));
    assert!(
        result.approval_requests.is_empty(),
        "a pending grant already exists, so no new grant is requested"
    );
}

#[test]
fn approval_gate_approved_grant_traverses_to_finish_allow() {
    let graph = approval_spawn_graph(true);

    let result = graph.simulate(&spawn_input(grant(PolicyApprovalState::Approved)));

    assert!(result.decision.is_allow());
    assert_eq!(
        result.visited_node_ids,
        vec![
            "gate-spawn".to_owned(),
            "approve-spawn".to_owned(),
            "finish-allow".to_owned(),
        ]
    );
    assert!(result.approval_requests.is_empty());
}

#[test]
fn approval_gate_denied_grant_terminates_as_deny() {
    let graph = approval_spawn_graph(true);

    let result = graph.simulate(&spawn_input(grant(PolicyApprovalState::Denied)));

    assert!(matches!(result.decision, PolicyDecision::Deny { .. }));
    assert!(result.approval_requests.is_empty());
}

#[test]
fn approval_gate_revoked_grant_terminates_as_deny() {
    let graph = approval_spawn_graph(true);

    let result = graph.simulate(&spawn_input(grant(PolicyApprovalState::Revoked)));

    assert!(matches!(result.decision, PolicyDecision::Deny { .. }));
    assert!(result.approval_requests.is_empty());
}

#[test]
fn approval_spawn_graph_with_terminal_route_validates() {
    let report = approval_spawn_graph(true).validate();
    assert!(
        report.is_valid(),
        "spawn -> approval -> finish is a terminal route: {:?}",
        report.issues
    );
}

#[test]
fn spawn_route_without_terminal_is_a_validation_error() {
    let report = approval_spawn_graph(false).validate();
    assert!(
        report.issues.iter().any(|issue| matches!(
            issue,
            PolicyGraphValidationIssue::SpawnRouteMissingTerminal { node_id }
                if node_id == "approve-spawn"
        )),
        "a dangling approved output must fail the spawn-terminal invariant: {:?}",
        report.issues
    );
}

#[test]
fn seeded_default_spawn_route_validates() {
    // The seeded Default graph routes spawn_agent to an explicit default-allow
    // terminal and must keep validating under the spawn-terminal invariant.
    let report = PolicyGraph::seeded_v2().validate();
    assert!(
        report.issues.iter().all(|issue| !matches!(
            issue,
            PolicyGraphValidationIssue::SpawnRouteMissingTerminal { .. }
        )),
        "seeded default graph must not violate the spawn-terminal invariant: {:?}",
        report.issues
    );
}
