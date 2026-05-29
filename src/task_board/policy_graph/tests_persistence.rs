use super::*;

#[test]
fn save_draft_rejects_stale_revision() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let seeded = store.load_or_seed().expect("seed policy graph");
    let baseline_revision = seeded.revision;
    let first = store
        .save_draft(seeded.clone(), baseline_revision)
        .expect("save first draft");
    assert!(first.persisted, "valid draft must persist");

    let stale_attempt = store.save_draft(seeded, baseline_revision);
    let error = stale_attempt.expect_err("stale revision must be rejected");
    let detail = error.to_string();
    let kind = error.kind().clone();
    assert!(
        matches!(kind, CliErrorKind::Workflow(_)),
        "expected workflow error, got {kind:?}",
    );
    assert!(
        detail.contains("revision conflict"),
        "unexpected error detail: {detail}",
    );
}

#[test]
fn save_draft_rejects_invalid_graph() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let baseline = store.load_or_seed().expect("seed policy graph");
    let mut invalid = baseline.clone();
    invalid.edges.push(PolicyGraphEdge {
        id: "edge:dangling".to_string(),
        from_node: "no-such-node".to_string(),
        from_port: "out".to_string(),
        to_node: "no-such-node".to_string(),
        to_port: PORT_IN.to_string(),
        label: None,
        condition: PolicyGraphEdgeCondition::Always,
    });

    let response = store.save_draft(invalid, 0).expect("save returns response");
    assert!(!response.persisted, "invalid drafts must not persist");
    assert!(
        !response.validation.is_valid(),
        "validation must surface issues for invalid drafts",
    );

    let on_disk = store
        .load_or_seed()
        .expect("load policy graph after rejected save");
    assert_eq!(
        on_disk.revision, baseline.revision,
        "rejected drafts must not bump on-disk revision",
    );
    assert_eq!(
        on_disk, baseline,
        "rejected drafts must leave on-disk graph unchanged",
    );
}

#[test]
fn evaluate_graph_uses_visited_set_not_counter() {
    // Seed has 11 nodes; the previous counter capped at `nodes.len() + 1`.
    // Pad the graph with unconnected nodes so the visited-set check is the
    // structural guard (rather than the loop counter) keeping evaluation
    // bounded.
    let mut graph = PolicyGraph::seeded_v2();
    let template = graph
        .nodes
        .iter()
        .find(|node| node.id == "supervisor:default-allow")
        .cloned()
        .expect("supervisor node");
    for index in 0..32 {
        let mut cloned = template.clone();
        cloned.id = format!("supervisor:padding-{index}");
        graph.nodes.push(cloned);
    }
    assert!(graph.validate().is_valid(), "padded graph stays valid");

    let simulation = graph.simulate(&PolicyInput::new(PolicyAction::SpawnAgent));
    let reason = match simulation.decision {
        PolicyDecision::Allow { reason_code, .. } => reason_code,
        other => panic!("unexpected decision: {other:?}"),
    };
    assert_eq!(reason, PolicyReasonCode::DefaultAllow);
    let mut visited_seen = std::collections::HashSet::new();
    for node_id in &simulation.visited_node_ids {
        assert!(
            visited_seen.insert(node_id.clone()),
            "evaluation revisited node {node_id} (visited: {:?})",
            simulation.visited_node_ids,
        );
    }
}

#[test]
fn load_workspace_or_seed_migrates_legacy_policy_files_into_default_canvas() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let mut legacy_document = PolicyGraph::seeded_v2();
    legacy_document.revision = 42;
    legacy_document.policy_trace_ids = vec!["legacy-trace".to_string()];
    let legacy_simulation = PolicyPipelineSimulationResult {
        revision: legacy_document.revision,
        trace_id: "legacy-simulation".to_string(),
        simulated_at: "2026-05-29T13:30:00Z".to_string(),
        succeeded: true,
        validation: legacy_document.validate(),
        decisions: Vec::new(),
        policy_trace_ids: legacy_document.policy_trace_ids.clone(),
        has_runtime_boundaries: false,
    };
    write_json_pretty(
        &temp.path().join("policy-pipeline-v2.json"),
        &legacy_document,
    )
    .expect("write legacy policy graph");
    write_json_pretty(
        &temp.path().join("policy-pipeline-v2-simulation.json"),
        &legacy_simulation,
    )
    .expect("write legacy simulation");

    let workspace = store
        .load_workspace_or_seed()
        .expect("load migrated policy canvas workspace");

    assert_eq!(
        workspace.canvases.len(),
        1,
        "legacy state should seed one canvas"
    );
    let active = active_canvas(&workspace);
    assert_eq!(active.title, "Primary policy");
    assert_eq!(active.document, legacy_document);
    assert_eq!(
        active
            .latest_simulation
            .as_ref()
            .map(|simulation| simulation.trace_id.as_str()),
        Some("legacy-simulation"),
    );
    assert_eq!(
        store.load_or_seed().expect("compatibility load"),
        legacy_document,
        "legacy compatibility getter should still surface the active canvas document",
    );
}

