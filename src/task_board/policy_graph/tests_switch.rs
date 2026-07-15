use super::*;

#[test]
fn switch_routes_to_the_first_matching_case() {
    let graph = switch_graph(json!([
        {
            "port": "case_1",
            "field": "checks_green",
            "predicate": { "predicate": "is_true" }
        },
        {
            "port": "case_2",
            "field": "branch_protection_allows_merge",
            "predicate": { "predicate": "is_true" }
        }
    ]));

    let result = graph.simulate(&PolicyInput {
        workflow: Some("reviews_auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence {
            checks_green: Some(true),
            branch_protection_allows_merge: Some(true),
            ..PolicyEvidence::default()
        },
        evaluated_at: None,
        approvals: Vec::new(),
    });

    assert_eq!(
        result.visited_node_ids,
        vec![
            "entry-reviews-auto".to_owned(),
            "switch-merge-evaluation".to_owned(),
            "finish-case-1".to_owned(),
        ]
    );
    assert_eq!(
        result.decision,
        PolicyDecision::Allow {
            reason_code: PolicyReasonCode::DefaultAllow,
            policy_version: "task-board-policy-v1".to_owned(),
        }
    );
}

#[test]
fn switch_routes_to_default_when_no_case_matches() {
    let graph = switch_graph(json!([
        {
            "port": "case_1",
            "field": "checks_green",
            "predicate": { "predicate": "is_true" }
        }
    ]));

    let result = graph.simulate(&PolicyInput {
        workflow: Some("reviews_auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence {
            checks_green: Some(false),
            ..PolicyEvidence::default()
        },
        evaluated_at: None,
        approvals: Vec::new(),
    });

    assert_eq!(
        result.visited_node_ids,
        vec![
            "entry-reviews-auto".to_owned(),
            "switch-merge-evaluation".to_owned(),
            "finish-default".to_owned(),
        ]
    );
    assert_eq!(
        result.decision,
        PolicyDecision::Deny {
            reason_code: PolicyReasonCode::ChecksNotGreen,
            policy_version: "task-board-policy-v1".to_owned(),
        }
    );
}

#[test]
fn switch_routes_missing_evidence_through_is_missing_cases() {
    let graph = switch_graph(json!([
        {
            "port": "case_1",
            "field": "checks_green",
            "predicate": { "predicate": "is_missing" }
        }
    ]));

    let result = graph.simulate(&PolicyInput {
        workflow: Some("reviews_auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence::default(),
        evaluated_at: None,
        approvals: Vec::new(),
    });

    assert_eq!(
        result.visited_node_ids,
        vec![
            "entry-reviews-auto".to_owned(),
            "switch-merge-evaluation".to_owned(),
            "finish-case-1".to_owned(),
        ]
    );
    assert_eq!(
        result.decision,
        PolicyDecision::Allow {
            reason_code: PolicyReasonCode::DefaultAllow,
            policy_version: "task-board-policy-v1".to_owned(),
        }
    );
}

fn switch_graph(arms: serde_json::Value) -> PolicyGraph {
    let arm_ports: Vec<String> = arms
        .as_array()
        .expect("switch arms array")
        .iter()
        .map(|arm| {
            arm.get("port")
                .and_then(serde_json::Value::as_str)
                .expect("switch arm port")
                .to_owned()
        })
        .collect();
    let output_ports: Vec<String> = arms
        .as_array()
        .expect("switch arms array")
        .iter()
        .map(|arm| {
            arm.get("port")
                .and_then(serde_json::Value::as_str)
                .expect("switch arm port")
                .to_owned()
        })
        .chain(std::iter::once("default".to_owned()))
        .collect();
    let mut edges = vec![
        json!({
            "id": "edge-entry-to-switch",
            "from_node": "entry-reviews-auto",
            "from_port": "out",
            "to_node": "switch-merge-evaluation",
            "to_port": "in",
            "condition": {
                "condition": "always"
            }
        }),
        json!({
            "id": "edge-switch-default",
            "from_node": "switch-merge-evaluation",
            "from_port": "default",
            "to_node": "finish-default",
            "to_port": "in",
            "condition": {
                "condition": "always"
            }
        }),
    ];
    if arm_ports.iter().any(|port| port == "case_1") {
        edges.push(json!({
            "id": "edge-switch-case-1",
            "from_node": "switch-merge-evaluation",
            "from_port": "case_1",
            "to_node": "finish-case-1",
            "to_port": "in",
            "condition": {
                "condition": "always"
            }
        }));
    }
    if arm_ports.iter().any(|port| port == "case_2") {
        edges.push(json!({
            "id": "edge-switch-case-2",
            "from_node": "switch-merge-evaluation",
            "from_port": "case_2",
            "to_node": "finish-case-2",
            "to_port": "in",
            "condition": {
                "condition": "always"
            }
        }));
    }
    serde_json::from_value(json!({
        "schema_version": 2,
        "revision": 1,
        "mode": "draft",
        "nodes": [
            {
                "id": "entry-reviews-auto",
                "label": "Reviews Auto",
                "kind": {
                    "kind": "workflow_entry",
                    "workflow_id": "reviews_auto"
                },
                "input_ports": [],
                "output_ports": ["out"]
            },
            {
                "id": "switch-merge-evaluation",
                "label": "Merge switch",
                "kind": {
                    "kind": "switch",
                    "arms": arms
                },
                "input_ports": ["in"],
                "output_ports": output_ports
            },
            {
                "id": "finish-case-1",
                "label": "Case 1",
                "kind": {
                    "kind": "finish",
                    "decision": "allow",
                    "reason_code": "default_allow"
                },
                "input_ports": ["in"],
                "output_ports": []
            },
            {
                "id": "finish-case-2",
                "label": "Case 2",
                "kind": {
                    "kind": "finish",
                    "decision": "deny",
                    "reason_code": "branch_protection_blocked"
                },
                "input_ports": ["in"],
                "output_ports": []
            },
            {
                "id": "finish-default",
                "label": "Default",
                "kind": {
                    "kind": "finish",
                    "decision": "deny",
                    "reason_code": "checks_not_green"
                },
                "input_ports": ["in"],
                "output_ports": []
            }
        ],
        "edges": edges,
        "groups": [],
        "layout": {
            "nodes": []
        },
        "policy_trace_ids": []
    }))
    .expect("decode switch graph")
}
