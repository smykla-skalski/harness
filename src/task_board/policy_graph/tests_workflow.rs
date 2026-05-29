use super::*;

#[test]
fn workflow_entry_matches_reviews_auto_only() {
    let graph = reviews_auto_test_graph();
    let simulation = graph.simulate(&PolicyInput {
        workflow: Some("reviews_auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence::default(),
    });

    assert_eq!(
        simulation.trace.entry_node_id.as_deref(),
        Some("entry-reviews-auto")
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
fn workflow_entry_matches_case_insensitively() {
    let graph = reviews_auto_test_graph();
    let simulation = graph.simulate(&PolicyInput {
        workflow: Some("Reviews_Auto".to_owned()),
        action: PolicyAction::SubmitReview,
        subject: PolicySubject::default(),
        evidence: PolicyEvidence::default(),
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
    let temp = tempdir().expect("create tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let save_response = store
        .save_draft(wait_for_checks_graph(), 0)
        .expect("save draft should succeed");
    assert!(save_response.persisted, "wait graph should persist");

    let simulation = store
        .simulate(Some(save_response.document.clone()))
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

    PolicyCanvasWorkspaceStore::new(temp.path().to_path_buf())
        .update(|workspace| {
            let simulation = workspace
                .active_canvas_mut()
                .and_then(|canvas| canvas.latest_simulation.as_mut())
                .expect("active canvas simulation");
            for decision in &mut simulation.decisions {
                decision.boundaries.clear();
            }
            simulation.has_runtime_boundaries = false;
            Ok(())
        })
        .expect("rewrite simulation without boundaries");

    let err = store
        .promote(&PolicyPipelinePromoteRequest {
            revision: save_response.document.revision,
            actor: Some("test".to_owned()),
            canvas_id: None,
        })
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

