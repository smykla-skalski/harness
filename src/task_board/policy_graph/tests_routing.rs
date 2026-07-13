use super::*;

#[test]
fn if_then_else_routes_true_checks_to_the_then_branch() {
    let graph = if_then_else_graph();

    let result = graph.simulate(&PolicyInput {
        workflow: Some("reviews_auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence {
            checks_green: Some(true),
            ..PolicyEvidence::default()
        },
        evaluated_at: None,
    });

    assert_eq!(
        result.visited_node_ids,
        vec![
            "entry-reviews-auto".to_owned(),
            "conditional-checks-green".to_owned(),
            "finish-allow".to_owned(),
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
fn if_then_else_routes_failed_or_missing_checks_to_the_else_branch() {
    let graph = if_then_else_graph();

    let failed = graph.simulate(&PolicyInput {
        workflow: Some("reviews_auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence {
            checks_green: Some(false),
            ..PolicyEvidence::default()
        },
        evaluated_at: None,
    });
    let missing = graph.simulate(&PolicyInput {
        workflow: Some("reviews_auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence::default(),
        evaluated_at: None,
    });

    for simulation in [failed, missing] {
        assert_eq!(
            simulation.visited_node_ids,
            vec![
                "entry-reviews-auto".to_owned(),
                "conditional-checks-green".to_owned(),
                "finish-deny".to_owned(),
            ]
        );
        assert_eq!(
            simulation.decision,
            PolicyDecision::Deny {
                reason_code: PolicyReasonCode::ChecksNotGreen,
                policy_version: "task-board-policy-v1".to_owned(),
            }
        );
    }
}

#[test]
fn if_then_else_routes_numeric_zero_predicates_through_the_then_branch() {
    let graph = if_then_else_graph_with("unresolved_requested_changes", "is_zero");

    let zero = graph.simulate(&PolicyInput {
        workflow: Some("reviews_auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence {
            unresolved_requested_changes: Some(0),
            ..PolicyEvidence::default()
        },
        evaluated_at: None,
    });
    let positive = graph.simulate(&PolicyInput {
        workflow: Some("reviews_auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence {
            unresolved_requested_changes: Some(2),
            ..PolicyEvidence::default()
        },
        evaluated_at: None,
    });

    assert_eq!(
        zero.visited_node_ids,
        vec![
            "entry-reviews-auto".to_owned(),
            "conditional-checks-green".to_owned(),
            "finish-allow".to_owned(),
        ]
    );
    assert_eq!(
        zero.decision,
        PolicyDecision::Allow {
            reason_code: PolicyReasonCode::DefaultAllow,
            policy_version: "task-board-policy-v1".to_owned(),
        }
    );
    assert_eq!(
        positive.visited_node_ids,
        vec![
            "entry-reviews-auto".to_owned(),
            "conditional-checks-green".to_owned(),
            "finish-deny".to_owned(),
        ]
    );
    assert_eq!(
        positive.decision,
        PolicyDecision::Deny {
            reason_code: PolicyReasonCode::ChecksNotGreen,
            policy_version: "task-board-policy-v1".to_owned(),
        }
    );
}

#[test]
fn if_then_else_routes_present_evidence_through_the_then_branch() {
    let graph = if_then_else_graph_with("checks_green", "is_present");

    let present = graph.simulate(&PolicyInput {
        workflow: Some("reviews_auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence {
            checks_green: Some(false),
            ..PolicyEvidence::default()
        },
        evaluated_at: None,
    });
    let missing = graph.simulate(&PolicyInput {
        workflow: Some("reviews_auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence::default(),
        evaluated_at: None,
    });

    assert_eq!(
        present.visited_node_ids,
        vec![
            "entry-reviews-auto".to_owned(),
            "conditional-checks-green".to_owned(),
            "finish-allow".to_owned(),
        ]
    );
    assert_eq!(
        present.decision,
        PolicyDecision::Allow {
            reason_code: PolicyReasonCode::DefaultAllow,
            policy_version: "task-board-policy-v1".to_owned(),
        }
    );
    assert_eq!(
        missing.visited_node_ids,
        vec![
            "entry-reviews-auto".to_owned(),
            "conditional-checks-green".to_owned(),
            "finish-deny".to_owned(),
        ]
    );
    assert_eq!(
        missing.decision,
        PolicyDecision::Deny {
            reason_code: PolicyReasonCode::ChecksNotGreen,
            policy_version: "task-board-policy-v1".to_owned(),
        }
    );
}

pub(super) fn merge_evidence(green: bool, protected_path: bool, risk_score: u8) -> PolicyEvidence {
    PolicyEvidence {
        checks_green: Some(green),
        branch_protection_allows_merge: Some(true),
        reviewer_verdict_approved: Some(true),
        unresolved_requested_changes: Some(0),
        protected_path_touched: Some(protected_path),
        risk_score: Some(risk_score),
        ..PolicyEvidence::default()
    }
}

fn if_then_else_graph() -> PolicyGraph {
    if_then_else_graph_with("checks_green", "is_true")
}

fn if_then_else_graph_with(field: &str, predicate: &str) -> PolicyGraph {
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
                "id": "conditional-checks-green",
                "label": "Checks green?",
                "kind": {
                    "kind": "if_then_else",
                    "field": field,
                    "predicate": {
                        "predicate": predicate
                    }
                },
                "input_ports": ["in"],
                "output_ports": ["then", "else"]
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
            },
            {
                "id": "finish-deny",
                "label": "Deny",
                "kind": {
                    "kind": "finish",
                    "decision": "deny",
                    "reason_code": "checks_not_green"
                },
                "input_ports": ["in"],
                "output_ports": []
            }
        ],
        "edges": [
            {
                "id": "edge-entry-to-conditional",
                "from_node": "entry-reviews-auto",
                "from_port": "out",
                "to_node": "conditional-checks-green",
                "to_port": "in",
                "condition": {
                    "condition": "always"
                }
            },
            {
                "id": "edge-conditional-then",
                "from_node": "conditional-checks-green",
                "from_port": "then",
                "to_node": "finish-allow",
                "to_port": "in",
                "condition": {
                    "condition": "condition_true"
                }
            },
            {
                "id": "edge-conditional-else",
                "from_node": "conditional-checks-green",
                "from_port": "else",
                "to_node": "finish-deny",
                "to_port": "in",
                "condition": {
                    "condition": "condition_false"
                }
            }
        ],
        "groups": [],
        "layout": {
            "nodes": []
        },
        "policy_trace_ids": []
    }))
    .expect("decode if_then_else graph")
}
