use temp_env::with_vars;
use tempfile::tempdir;

use crate::task_board::policy::{
    BuiltInPolicyGate, PolicyAction, PolicyDecision, PolicyEvidence, PolicyGate, PolicyInput,
    PolicyReasonCode,
};

use super::{
    GraphPolicyGate, PORT_IN, PolicyGraph, PolicyGraphEdge, PolicyGraphEdgeCondition,
    PolicyGraphMode, PolicyGraphNodeKind, PolicyGraphValidationIssue, PolicyPipelinePromoteRequest,
    PolicyPipelineStore,
};

#[test]
fn seeded_graph_serializes_as_v2_draft() {
    let graph = PolicyGraph::seeded_v2();

    assert_eq!(graph.schema_version, 2);
    assert_eq!(graph.revision, 1);
    assert_eq!(graph.mode, PolicyGraphMode::Draft);
    assert!(graph.validate().is_valid());
    assert!(!graph.nodes.is_empty());
    assert!(!graph.edges.is_empty());
}

#[test]
fn validation_reports_dangling_edges_invalid_ports_and_cycles() {
    let mut graph = PolicyGraph::seeded_v2();
    graph.edges.push(PolicyGraphEdge {
        id: "edge:bad-node".to_string(),
        from_node: "missing".to_string(),
        from_port: "out".to_string(),
        to_node: "action:router".to_string(),
        to_port: PORT_IN.to_string(),
        condition: PolicyGraphEdgeCondition::Always,
    });
    graph.edges.push(PolicyGraphEdge {
        id: "edge:bad-port".to_string(),
        from_node: "action:router".to_string(),
        from_port: "nope".to_string(),
        to_node: "supervisor:default-allow".to_string(),
        to_port: PORT_IN.to_string(),
        condition: PolicyGraphEdgeCondition::Always,
    });
    graph.edges.push(PolicyGraphEdge {
        id: "edge:cycle".to_string(),
        from_node: "supervisor:default-allow".to_string(),
        from_port: "out".to_string(),
        to_node: "action:router".to_string(),
        to_port: PORT_IN.to_string(),
        condition: PolicyGraphEdgeCondition::Always,
    });

    let report = graph.validate();

    assert!(
        report
            .issues
            .iter()
            .any(|issue| matches!(issue, PolicyGraphValidationIssue::DanglingEdge { .. }))
    );
    assert!(
        report
            .issues
            .iter()
            .any(|issue| matches!(issue, PolicyGraphValidationIssue::InvalidPort { .. }))
    );
    assert!(
        report
            .issues
            .iter()
            .any(|issue| matches!(issue, PolicyGraphValidationIssue::Cycle { .. }))
    );
}

#[test]
fn default_graph_matches_builtin_policy_outcomes() {
    let graph = GraphPolicyGate::new(PolicyGraph::seeded_v2());
    let builtin = BuiltInPolicyGate::default();
    let cases = [
        PolicyInput::new(PolicyAction::SpawnAgent),
        PolicyInput::new(PolicyAction::MutateRepo),
        PolicyInput::new(PolicyAction::DeleteWorktree),
        PolicyInput::new(PolicyAction::MergePr),
        PolicyInput::new(PolicyAction::MergePr).with_evidence(merge_evidence(false, false, 0)),
        PolicyInput::new(PolicyAction::MergePr).with_evidence(merge_evidence(true, true, 0)),
        PolicyInput::new(PolicyAction::MergePr).with_evidence(merge_evidence(true, false, 99)),
    ];

    for input in cases {
        assert_eq!(graph.evaluate(&input), builtin.evaluate(&input));
    }
}

#[test]
fn promotion_requires_exact_successful_simulation_revision() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let mut document = store.load_or_seed().expect("seed policy graph");
    document.nodes.iter_mut().for_each(|node| {
        if let PolicyGraphNodeKind::ActionGate { actions } = &mut node.kind {
            actions.retain(|action| *action != PolicyAction::DeleteWorktree);
        }
    });
    let saved = store.save_draft(document).expect("save draft");

    let failed = store.promote(&PolicyPipelinePromoteRequest {
        revision: saved.document.revision,
        actor: None,
    });
    assert!(failed.is_err());

    let simulation = store
        .simulate(Some(saved.document.clone()))
        .expect("simulate policy graph");
    assert!(simulation.succeeded);
    assert_eq!(simulation.revision, saved.document.revision);

    let promoted = store
        .promote(&PolicyPipelinePromoteRequest {
            revision: saved.document.revision,
            actor: None,
        })
        .expect("promote policy graph");

    assert_eq!(promoted.document.mode, PolicyGraphMode::Enforced);
    assert_eq!(promoted.document.revision, saved.document.revision);
}

#[test]
fn store_seeds_default_under_isolated_xdg_home() {
    let temp = tempdir().expect("tempdir");
    with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(temp.path().to_string_lossy().to_string()),
            ),
            ("CLAUDE_SESSION_ID", Some("policy-graph-tests".to_string())),
        ],
        || {
            let store = PolicyPipelineStore::new(temp.path().to_path_buf());
            assert!(
                store
                    .load_or_seed()
                    .expect("seed policy graph")
                    .validate()
                    .is_valid()
            );
        },
    );
}

#[test]
fn reason_codes_are_stable_for_key_default_paths() {
    let graph = PolicyGraph::seeded_v2();
    let decision = graph
        .simulate(&PolicyInput::new(PolicyAction::MergePr))
        .decision;
    let reason = match decision {
        PolicyDecision::RequireHuman { reason_code, .. } => reason_code,
        other => panic!("unexpected decision: {other:?}"),
    };

    assert_eq!(reason, PolicyReasonCode::MissingMergeEvidence);
}

fn merge_evidence(green: bool, protected_path: bool, risk_score: u8) -> PolicyEvidence {
    PolicyEvidence {
        checks_green: Some(green),
        branch_protection_allows_merge: Some(true),
        reviewer_verdict_approved: Some(true),
        unresolved_requested_changes: Some(0),
        protected_path_touched: Some(protected_path),
        risk_score: Some(risk_score),
    }
}
