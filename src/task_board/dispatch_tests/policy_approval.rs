use std::collections::HashMap;

use crate::task_board::policy::{
    PolicyAction, PolicyApprovalGrant, PolicyApprovalState, PolicyDecision, PolicyReasonCode,
};
use crate::task_board::policy_graph::PolicyGraph;

use super::{DispatchPlan, SpawnGateSwitches, build_dispatch_plans_with_policy, ready_item};

/// `ActionGate[spawn_agent] -> ApprovalGate -> Finish(allow)`: the manual spawn
/// approval policy the dispatch lifecycle drives grants through.
fn approval_spawn_graph() -> PolicyGraph {
    let graph = serde_json::json!({
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
                "kind": { "kind": "approval_gate", "reason_code": "approval_required" },
                "input_ports": ["in"],
                "output_ports": ["approved"]
            },
            {
                "id": "finish-allow",
                "label": "Allow",
                "kind": { "kind": "finish", "decision": "allow", "reason_code": "default_allow" },
                "input_ports": ["in"],
                "output_ports": []
            }
        ],
        "edges": [
            {
                "id": "edge-gate-to-approval",
                "from_node": "gate-spawn",
                "from_port": "match",
                "to_node": "approve-spawn",
                "to_port": "in",
                "condition": { "condition": "action_in", "actions": ["spawn_agent"] }
            },
            {
                "id": "edge-approval-to-finish",
                "from_node": "approve-spawn",
                "from_port": "approved",
                "to_node": "finish-allow",
                "to_port": "in",
                "condition": { "condition": "always" }
            }
        ],
        "groups": [],
        "layout": {}
    });
    serde_json::from_value(graph).expect("approval spawn graph deserializes")
}

fn test_grant(state: PolicyApprovalState) -> PolicyApprovalGrant {
    PolicyApprovalGrant {
        id: "policy-grant-test".to_owned(),
        board_item_id: "task-1".to_owned(),
        action: PolicyAction::SpawnAgent,
        canvas_id: Some("canvas-1".to_owned()),
        canvas_revision: 1,
        node_id: "approve-spawn".to_owned(),
        reason_code: PolicyReasonCode::ApprovalRequired,
        state,
        resolved_by: None,
        resolved_at: None,
        consumed_at: None,
        expiry_seconds: None,
        created_at: "2026-07-14T00:00:00Z".to_owned(),
        updated_at: "2026-07-14T00:00:00Z".to_owned(),
    }
}

fn dispatch_with_grant(grant: Option<PolicyApprovalGrant>) -> DispatchPlan {
    let graph = approval_spawn_graph();
    let mut grants = HashMap::new();
    if let Some(grant) = grant {
        grants.insert("task-1".to_owned(), grant);
    }
    build_dispatch_plans_with_policy(
        &[ready_item()],
        Some(("canvas-1", &graph)),
        None,
        SpawnGateSwitches::default(),
        &grants,
    )
    .into_iter()
    .next()
    .expect("one plan")
}

#[test]
fn approved_grant_allows_spawn_and_marks_the_grant_for_consumption() {
    let plan = dispatch_with_grant(Some(test_grant(PolicyApprovalState::Approved)));
    assert!(plan.policy.is_allow());
    assert_eq!(
        plan.consumed_approval_grant_id.as_deref(),
        Some("policy-grant-test"),
        "an approved grant that clears its gate is marked for one-shot consumption"
    );
}

#[test]
fn pending_grant_blocks_spawn_and_consumes_nothing() {
    let plan = dispatch_with_grant(Some(test_grant(PolicyApprovalState::Pending)));
    assert!(matches!(plan.policy, PolicyDecision::RequireHuman { .. }));
    assert!(plan.consumed_approval_grant_id.is_none());
}

#[test]
fn missing_grant_blocks_spawn_and_consumes_nothing() {
    let plan = dispatch_with_grant(None);
    assert!(matches!(plan.policy, PolicyDecision::RequireHuman { .. }));
    assert!(plan.consumed_approval_grant_id.is_none());
}

#[test]
fn denied_grant_denies_spawn_and_consumes_nothing() {
    let plan = dispatch_with_grant(Some(test_grant(PolicyApprovalState::Denied)));
    assert!(matches!(plan.policy, PolicyDecision::Deny { .. }));
    assert!(plan.consumed_approval_grant_id.is_none());
}
