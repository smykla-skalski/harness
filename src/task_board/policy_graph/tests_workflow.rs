use super::*;
use crate::task_board::policy_graph::{CompiledWorkflowStep, PolicyHandoffStep};

#[test]
fn workflow_entry_matches_reviews_auto_only() {
    let graph = reviews_auto_test_graph();
    let simulation = graph.simulate(&PolicyInput {
        workflow: Some("reviews_auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence::default(),
        evaluated_at: None,
    });

    assert_eq!(
        simulation.trace.entry_node_id.as_deref(),
        Some("entry-reviews-auto")
    );
}

#[test]
fn direct_input_does_not_fallback_to_workflow_internal_action_gate() {
    let graph = workflow_only_action_gate_graph();

    let direct = graph.simulate(&PolicyInput {
        workflow: None,
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence::default(),
        evaluated_at: None,
    });
    assert!(
        direct.visited_node_ids.is_empty(),
        "direct review approval unexpectedly entered workflow nodes: {:?}",
        direct.visited_node_ids
    );

    let workflow = graph.simulate(&PolicyInput {
        workflow: Some("reviews_auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence::default(),
        evaluated_at: None,
    });
    assert_eq!(
        workflow.visited_node_ids,
        vec![
            "reviews-auto-entry".to_owned(),
            "reviews-auto-action-router".to_owned(),
        ],
    );
}

#[test]
fn compile_workflow_requires_a_matching_entry() {
    let graph = reviews_auto_test_graph();
    let input = PolicyInput {
        workflow: Some("reviews_auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence::default(),
        evaluated_at: None,
    };
    assert!(
        graph.compile_workflow("reviews_auto", &input).is_some(),
        "an authored workflow should compile"
    );
    assert!(
        graph.compile_workflow("does_not_exist", &input).is_none(),
        "an unknown workflow must not borrow the built-in gate fallback"
    );
}

#[test]
fn compile_workflow_emits_a_handoff_step_for_a_handoff_node() {
    let graph = handoff_graph();
    let input = PolicyInput {
        workflow: Some("reviews_auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence::default(),
        evaluated_at: None,
    };
    let plan = graph
        .compile_workflow("reviews_auto", &input)
        .expect("a handoff workflow compiles");
    assert!(
        plan.steps.iter().any(|step| matches!(
            step,
            CompiledWorkflowStep::Handoff { handoff_key } if handoff_key == "next-handler"
        )),
        "a handoff node compiles to a runnable handoff step, not a block: {:?}",
        plan.steps
    );
    assert!(
        plan.blocked_reason.is_none(),
        "a handoff no longer blocks the compiled plan"
    );
}

fn handoff_graph() -> PolicyGraph {
    let mut graph = reviews_auto_test_graph();
    graph.nodes.insert(
        2,
        PolicyGraphNode {
            id: "handoff-next".into(),
            label: "Hand off".to_owned(),
            kind: PolicyGraphNodeKind::Handoff(PolicyHandoffStep {
                handoff_key: "next-handler".to_owned(),
            }),
            automation: None,
            input_ports: vec![PORT_IN.into()],
            output_ports: vec!["out".into()],
            group_id: Some("workflow-entry".into()),
        },
    );
    let edge = graph
        .edges
        .iter_mut()
        .find(|edge| edge.from_node == "entry-reviews-auto" && edge.to_node == "action:router")
        .expect("reviews auto entry edge");
    edge.to_node = "handoff-next".into();
    graph.edges.push(PolicyGraphEdge {
        id: "edge:handoff-to-router".into(),
        from_node: "handoff-next".into(),
        from_port: "out".into(),
        to_node: "action:router".into(),
        to_port: PORT_IN.into(),
        label: None,
        condition: PolicyGraphEdgeCondition::Always,
    });
    let group = graph
        .groups
        .iter_mut()
        .find(|group| group.id == "workflow-entry")
        .expect("workflow entry group");
    group.node_ids.push("handoff-next".into());
    graph.layout.nodes.push(PolicyGraphNodeLayout {
        node_id: "handoff-next".into(),
        x: 24,
        y: 240,
        source: None,
    });
    graph
}

fn workflow_only_action_gate_graph() -> PolicyGraph {
    let mut graph = PolicyGraph::seeded_v2();
    graph.nodes.clear();
    graph.edges.clear();
    graph.groups.clear();
    graph.layout.nodes.clear();
    graph.nodes.push(PolicyGraphNode {
        id: "reviews-auto-entry".into(),
        label: "Reviews Auto".to_owned(),
        kind: PolicyGraphNodeKind::WorkflowEntry(PolicyWorkflowEntry {
            workflow_id: "reviews_auto".to_owned(),
        }),
        automation: None,
        input_ports: Vec::new(),
        output_ports: vec!["out".into()],
        group_id: None,
    });
    graph.nodes.push(PolicyGraphNode {
        id: "reviews-auto-action-router".into(),
        label: "Action gate".to_owned(),
        kind: PolicyGraphNodeKind::ActionGate {
            actions: vec![PolicyAction::SubmitReview],
        },
        automation: None,
        input_ports: vec![PORT_IN.into()],
        output_ports: Vec::new(),
        group_id: None,
    });
    graph.edges.push(PolicyGraphEdge {
        id: "edge:reviews-auto-entry-action-router".into(),
        from_node: "reviews-auto-entry".into(),
        from_port: "out".into(),
        to_node: "reviews-auto-action-router".into(),
        to_port: PORT_IN.into(),
        label: None,
        condition: PolicyGraphEdgeCondition::Always,
    });
    graph
}

#[test]
fn workflow_entry_matches_case_insensitively() {
    let graph = reviews_auto_test_graph();
    let simulation = graph.simulate(&PolicyInput {
        workflow: Some("Reviews_Auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence::default(),
        evaluated_at: None,
    });

    assert_eq!(
        simulation.trace.entry_node_id.as_deref(),
        Some("entry-reviews-auto"),
        "a differently-cased workflow id must still resolve the authored entry"
    );
}

#[test]
fn orchestration_nodes_round_trip_through_policy_graph() {
    let node = PolicyGraphNodeKind::WaitStep(PolicyWaitStep {
        wait: PolicyWaitCondition::Timer {
            duration_seconds: 900,
        },
        resume_key: "checks-ready".to_owned(),
    });

    let value = serde_json::to_value(&node).expect("serialize node");
    let decoded: PolicyGraphNodeKind = serde_json::from_value(value).expect("decode node");

    assert_eq!(decoded, node);
}

#[test]
fn simulation_marks_wait_nodes_as_runtime_boundaries() {
    let graph = wait_for_checks_graph();

    let result = graph.simulate(&PolicyInput {
        workflow: Some("reviews_auto".to_owned()),
        action: PolicyAction::MergePr,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence::default(),
        evaluated_at: None,
    });

    assert_eq!(result.boundaries.len(), 1);
    assert_eq!(result.boundaries[0].node_id, "wait-checks");
    assert_eq!(result.boundaries[0].resume_key, "checks-ready");
    assert_eq!(
        result.boundaries[0].wait,
        PolicyWaitCondition::Event {
            event_key: "reviews.checks_passed".to_owned(),
        }
    );
}

#[test]
fn promote_rejects_revision_without_matching_boundary_aware_simulation() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let save_response = apply_save_draft(&mut ws, wait_for_checks_graph(), 0, None)
        .expect("save draft should succeed");
    assert!(save_response.persisted, "wait graph should persist");
    ws.scenarios.clear();
    ws.scenarios
        .push(crate::task_board::policy_graph::PolicyScenario {
            id: "scenario-reviews-auto".to_owned(),
            name: "reviews auto".to_owned(),
            input: PolicyInput {
                workflow: Some("reviews_auto".to_owned()),
                action: PolicyAction::MergePr,
                subject: PolicySubject::default(),
                evidence: PolicyEvidence::default(),
                evaluated_at: None,
            },
            seeded: false,
        });

    let simulation = apply_simulate(&mut ws, Some(save_response.document.clone()), None)
        .expect("simulate wait graph");
    assert!(simulation.succeeded, "wait graph simulation should succeed");
    assert!(
        simulation.has_runtime_boundaries,
        "wait graph simulation should record runtime boundaries"
    );
    assert!(
        simulation
            .decisions
            .iter()
            .any(|decision| !decision.boundaries.is_empty()),
        "wait graph simulation should persist at least one boundary-bearing decision"
    );

    // Directly mutate the stored simulation to strip boundary metadata, simulating
    // a stale simulation that lacks the required boundary-aware run.
    let stored_simulation = ws
        .active_canvas_mut()
        .and_then(|canvas| canvas.latest_simulation.as_mut())
        .expect("active canvas simulation");
    for decision in &mut stored_simulation.decisions {
        decision.boundaries.clear();
    }
    stored_simulation.has_runtime_boundaries = false;

    let err = apply_promote(
        &mut ws,
        &PolicyPipelinePromoteRequest {
            revision: save_response.document.revision,
            actor: Some("test".to_owned()),
            canvas_id: None,
        },
    )
    .expect_err("promotion should fail without boundary-aware simulation");

    let message = err.to_string();
    assert!(
        message.contains("simulation"),
        "error should mention simulation, got: {message}"
    );
    assert!(
        message.contains("runtime boundary"),
        "error should mention runtime boundary metadata, got: {message}"
    );
}
