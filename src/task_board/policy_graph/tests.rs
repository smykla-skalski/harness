use temp_env::with_vars;
use tempfile::tempdir;

use std::collections::HashMap;

use crate::errors::CliErrorKind;
use crate::infra::io::write_json_pretty;
use crate::task_board::policy::{
    BuiltInPolicyGate, PolicyAction, PolicyDecision, PolicyEvidence, PolicyGate, PolicyInput,
    PolicyReasonCode, PolicySubject,
};

use super::{
    GraphPolicyGate, PORT_IN, PolicyCanvasRecord, PolicyCanvasRect, PolicyCanvasWorkspace,
    PolicyCanvasWorkspaceStore, PolicyEvidencePredicate, PolicyGraph, PolicyGraphAutomationBinding,
    PolicyGraphEdge, PolicyGraphEdgeCondition, PolicyGraphGroup, PolicyGraphMode, PolicyGraphNode,
    PolicyGraphNodeKind, PolicyGraphNodeLayout, PolicyGraphValidationIssue,
    PolicyPipelinePromoteRequest, PolicyPipelineSimulationResult, PolicyPipelineStore,
    PolicyWaitCondition, PolicyWaitStep, PolicyWorkflowEntry,
};

const NODE_WIDTH: i32 = 168;
const NODE_HEIGHT: i32 = 96;

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
fn seeded_graph_layout_starts_clear_and_non_overlapping() {
    let graph = PolicyGraph::seeded_v2();
    let node_layouts: HashMap<_, _> = graph
        .layout
        .nodes
        .iter()
        .map(|layout| (layout.node_id.as_str(), layout))
        .collect();

    for group in &graph.groups {
        assert!(group.frame.x >= 0, "group starts left of canvas: {group:?}");
        assert!(group.frame.y >= 0, "group starts above canvas: {group:?}");
        assert!(group.frame.width > 0, "group has empty width: {group:?}");
        assert!(group.frame.height > 0, "group has empty height: {group:?}");
        for node_id in &group.node_ids {
            let layout = node_layouts
                .get(node_id.as_str())
                .unwrap_or_else(|| panic!("missing layout for {node_id}"));
            assert!(
                rect_contains_node(&group.frame, layout),
                "node {node_id} is outside group {group:?}: {layout:?}"
            );
        }
    }

    for left_index in 0..graph.groups.len() {
        for right_index in (left_index + 1)..graph.groups.len() {
            assert!(
                !rects_intersect(
                    &graph.groups[left_index].frame,
                    &graph.groups[right_index].frame
                ),
                "seeded groups overlap: {:?} and {:?}",
                graph.groups[left_index],
                graph.groups[right_index]
            );
        }
    }
}

#[test]
fn node_automation_binding_round_trips_as_policy_graph_metadata() {
    let mut graph = PolicyGraph::seeded_v2();
    graph.nodes[0].automation = Some(PolicyGraphAutomationBinding {
        is_enabled: true,
        event_source: "clipboard".to_string(),
        priority: Some(3),
        content_kinds: vec!["image".to_string()],
        preprocessors: vec![
            "respectPasteboardPrivacy".to_string(),
            "dedupeByFingerprint".to_string(),
        ],
        actions: vec![
            "ocrImage".to_string(),
            "rememberRecentScan".to_string(),
            "recordMetadata".to_string(),
        ],
        postprocessors: vec!["persistResult".to_string(), "auditEvent".to_string()],
        source_app_mode: "allowedOnly".to_string(),
        allowed_bundle_identifiers: vec!["com.example.notes".to_string()],
        denied_bundle_identifiers: vec![],
    });

    let encoded = serde_json::to_string(&graph).expect("serialize graph");
    assert!(encoded.contains("\"automation\""));
    assert!(encoded.contains("\"event_source\":\"clipboard\""));

    let decoded: PolicyGraph = serde_json::from_str(&encoded).expect("decode graph");
    let binding = decoded.nodes[0]
        .automation
        .as_ref()
        .expect("automation binding");
    assert_eq!(binding.event_source, "clipboard");
    assert_eq!(binding.content_kinds, vec!["image".to_string()]);
    assert_eq!(
        binding.allowed_bundle_identifiers,
        vec!["com.example.notes".to_string()]
    );
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
        label: None,
        condition: PolicyGraphEdgeCondition::Always,
    });
    graph.edges.push(PolicyGraphEdge {
        id: "edge:bad-port".to_string(),
        from_node: "action:router".to_string(),
        from_port: "nope".to_string(),
        to_node: "supervisor:default-allow".to_string(),
        to_port: PORT_IN.to_string(),
        label: None,
        condition: PolicyGraphEdgeCondition::Always,
    });
    graph.edges.push(PolicyGraphEdge {
        id: "edge:cycle".to_string(),
        from_node: "supervisor:default-allow".to_string(),
        from_port: "out".to_string(),
        to_node: "action:router".to_string(),
        to_port: PORT_IN.to_string(),
        label: None,
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
    let saved = store.save_draft(document, 0).expect("save draft");

    let failed = store.promote(&PolicyPipelinePromoteRequest {
        revision: saved.document.revision,
        actor: None,
        canvas_id: None,
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
            canvas_id: None,
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

#[test]
fn predicate_passes_is_positive_admits_count_evidence() {
    use super::evaluation::predicate_passes;

    assert!(
        !predicate_passes(PolicyEvidencePredicate::IsPositive, 0),
        "IsPositive must reject zero counts"
    );
    assert!(
        predicate_passes(PolicyEvidencePredicate::IsPositive, 1),
        "IsPositive must accept positive counts"
    );
    assert!(
        predicate_passes(PolicyEvidencePredicate::IsPositive, u32::MAX),
        "IsPositive must accept saturating counts"
    );
    assert!(
        predicate_passes(PolicyEvidencePredicate::IsTrue, 1),
        "IsTrue stays strictly bool",
    );
    assert!(
        !predicate_passes(PolicyEvidencePredicate::IsTrue, 2),
        "IsTrue must reject non-one counts to stay bool-only",
    );
}

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
fn switching_active_canvas_changes_compatibility_pipeline_target() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let workspace = store.load_workspace_or_seed().expect("seed workspace");
    let original_id = workspace.active_canvas_id.clone();
    let duplicate = store
        .duplicate_canvas(&original_id, Some("Experiment A".to_string()))
        .expect("duplicate canvas");
    let mut edited_document = duplicate.document.clone();
    edited_document.policy_trace_ids = vec!["experiment-a".to_string()];

    let updated_workspace = store
        .set_active_canvas(&duplicate.id)
        .expect("activate duplicate canvas");
    assert_eq!(updated_workspace.active_canvas_id, duplicate.id);

    let saved = store
        .save_draft(edited_document.clone(), duplicate.document.revision)
        .expect("save active duplicate");
    assert!(saved.persisted, "active duplicate draft should persist");
    assert_eq!(
        store.load_or_seed().expect("load active duplicate"),
        saved.document,
        "compatibility getter should follow the active canvas",
    );

    let restored_workspace = store
        .set_active_canvas(&original_id)
        .expect("restore original active canvas");
    assert_eq!(restored_workspace.active_canvas_id, original_id);
    assert_ne!(
        store.load_or_seed().expect("load restored original"),
        saved.document,
        "switching active canvas should restore the original compatibility target",
    );
}

#[test]
fn create_canvas_adds_new_seeded_draft_and_makes_it_active() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let initial_workspace = store.load_workspace_or_seed().expect("seed workspace");

    let created = store
        .create_canvas(Some("Net new".to_string()))
        .expect("create canvas");

    let workspace = store.load_workspace_or_seed().expect("reload workspace");
    assert_eq!(
        workspace.canvases.len(),
        initial_workspace.canvases.len() + 1
    );
    assert_eq!(workspace.active_canvas_id, created.id);

    let active = active_canvas(&workspace);
    assert_eq!(active.title, "Net new");
    assert_eq!(active.document.mode, PolicyGraphMode::Draft);
    assert!(
        active.document.validate().is_valid(),
        "new canvas should start valid"
    );
    assert_eq!(
        store.load_or_seed().expect("compatibility load"),
        active.document,
        "compatibility getter should point at the new active canvas",
    );
}

#[test]
fn delete_canvas_rejects_removing_the_last_canvas() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let workspace = store.load_workspace_or_seed().expect("seed workspace");

    let error = store
        .delete_canvas(&workspace.active_canvas_id)
        .expect_err("last canvas deletion must be rejected");
    let detail = error.to_string();

    assert!(
        detail.contains("last canvas"),
        "unexpected error detail: {detail}",
    );
}

#[test]
fn rename_canvas_updates_title_without_replacing_active_document() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let workspace = store.load_workspace_or_seed().expect("seed workspace");
    let baseline_document = store.load_or_seed().expect("load active canvas");

    let renamed_workspace = store
        .rename_canvas(&workspace.active_canvas_id, "Policies v2")
        .expect("rename active canvas");

    assert_eq!(active_canvas(&renamed_workspace).title, "Policies v2");
    assert_eq!(
        store.load_or_seed().expect("reload active document"),
        baseline_document,
        "renaming should not replace the active document",
    );
}

#[test]
fn save_draft_for_active_canvas_rejects_canvas_selection_conflict() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let workspace = store.load_workspace_or_seed().expect("seed workspace");
    let original_id = workspace.active_canvas_id.clone();
    let duplicate = store
        .duplicate_canvas(&original_id, Some("Experiment".to_string()))
        .expect("duplicate canvas");
    store
        .set_active_canvas(&duplicate.id)
        .expect("activate duplicate canvas");

    let error = store
        .save_draft_for_active_canvas(
            duplicate.document.clone(),
            duplicate.document.revision,
            Some(&original_id),
        )
        .expect_err("stale canvas selection must be rejected");
    let detail = error.to_string();

    assert!(
        detail.contains("canvas selection changed"),
        "unexpected error detail: {detail}",
    );
}

#[test]
fn promote_rejects_canvas_selection_conflict() {
    let temp = tempdir().expect("tempdir");
    let store = PolicyPipelineStore::new(temp.path().to_path_buf());
    let workspace = store.load_workspace_or_seed().expect("seed workspace");
    let original_id = workspace.active_canvas_id.clone();
    let duplicate = store
        .duplicate_canvas(&original_id, Some("Experiment".to_string()))
        .expect("duplicate canvas");
    store
        .set_active_canvas(&duplicate.id)
        .expect("activate duplicate canvas");

    let error = store
        .promote(&PolicyPipelinePromoteRequest {
            revision: duplicate.document.revision,
            actor: None,
            canvas_id: Some(original_id),
        })
        .expect_err("stale canvas selection must be rejected");
    let detail = error.to_string();

    assert!(
        detail.contains("canvas selection changed"),
        "unexpected error detail: {detail}",
    );
}

fn merge_evidence(green: bool, protected_path: bool, risk_score: u8) -> PolicyEvidence {
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

fn reviews_auto_test_graph() -> PolicyGraph {
    let mut graph = PolicyGraph::seeded_v2();
    graph.nodes.insert(
        0,
        PolicyGraphNode {
            id: "entry-reviews-auto".to_owned(),
            label: "Reviews Auto".to_owned(),
            kind: PolicyGraphNodeKind::WorkflowEntry(PolicyWorkflowEntry {
                workflow_id: "reviews_auto".to_owned(),
            }),
            automation: None,
            input_ports: vec![PORT_IN.to_owned()],
            output_ports: vec!["out".to_owned()],
            group_id: Some("workflow-entry".to_owned()),
        },
    );
    graph.nodes.insert(
        1,
        PolicyGraphNode {
            id: "entry-reviews-manual".to_owned(),
            label: "Reviews Manual".to_owned(),
            kind: PolicyGraphNodeKind::WorkflowEntry(PolicyWorkflowEntry {
                workflow_id: "reviews_manual".to_owned(),
            }),
            automation: None,
            input_ports: vec![PORT_IN.to_owned()],
            output_ports: vec!["out".to_owned()],
            group_id: Some("workflow-entry".to_owned()),
        },
    );
    graph.edges.push(PolicyGraphEdge {
        id: "edge:entry-reviews-auto".to_owned(),
        from_node: "entry-reviews-auto".to_owned(),
        from_port: "out".to_owned(),
        to_node: "action:router".to_owned(),
        to_port: PORT_IN.to_owned(),
        label: None,
        condition: PolicyGraphEdgeCondition::Always,
    });
    graph.edges.push(PolicyGraphEdge {
        id: "edge:entry-reviews-manual".to_owned(),
        from_node: "entry-reviews-manual".to_owned(),
        from_port: "out".to_owned(),
        to_node: "action:router".to_owned(),
        to_port: PORT_IN.to_owned(),
        label: None,
        condition: PolicyGraphEdgeCondition::Always,
    });
    graph.groups.push(PolicyGraphGroup {
        id: "workflow-entry".to_owned(),
        label: "Workflow entry".to_owned(),
        color: None,
        frame: PolicyCanvasRect {
            x: 0,
            y: 0,
            width: 260,
            height: 240,
        },
        node_ids: vec![
            "entry-reviews-auto".to_owned(),
            "entry-reviews-manual".to_owned(),
        ],
    });
    graph.layout.nodes.extend([
        PolicyGraphNodeLayout {
            node_id: "entry-reviews-auto".to_owned(),
            x: 24,
            y: 24,
        },
        PolicyGraphNodeLayout {
            node_id: "entry-reviews-manual".to_owned(),
            x: 24,
            y: 132,
        },
    ]);
    graph
}

fn rect_contains_node(frame: &PolicyCanvasRect, layout: &PolicyGraphNodeLayout) -> bool {
    layout.x >= frame.x
        && layout.y >= frame.y
        && layout.x + NODE_WIDTH <= frame.x + frame.width
        && layout.y + NODE_HEIGHT <= frame.y + frame.height
}

fn rects_intersect(left: &PolicyCanvasRect, right: &PolicyCanvasRect) -> bool {
    left.x < right.x + right.width
        && left.x + left.width > right.x
        && left.y < right.y + right.height
        && left.y + left.height > right.y
}

fn wait_for_checks_graph() -> PolicyGraph {
    let mut graph = reviews_auto_test_graph();
    graph.nodes.insert(
        2,
        PolicyGraphNode {
            id: "wait-checks".to_owned(),
            label: "Wait for checks".to_owned(),
            kind: PolicyGraphNodeKind::WaitStep(PolicyWaitStep {
                wait: PolicyWaitCondition::Event {
                    event_key: "reviews.checks_passed".to_owned(),
                },
                resume_key: "checks-ready".to_owned(),
            }),
            automation: None,
            input_ports: vec![PORT_IN.to_owned()],
            output_ports: vec!["out".to_owned()],
            group_id: Some("workflow-entry".to_owned()),
        },
    );
    let edge = graph
        .edges
        .iter_mut()
        .find(|edge| edge.from_node == "entry-reviews-auto" && edge.to_node == "action:router")
        .expect("reviews auto entry edge");
    edge.to_node = "wait-checks".to_owned();
    graph.edges.push(PolicyGraphEdge {
        id: "edge:wait-checks-to-router".to_owned(),
        from_node: "wait-checks".to_owned(),
        from_port: "out".to_owned(),
        to_node: "action:router".to_owned(),
        to_port: PORT_IN.to_owned(),
        label: None,
        condition: PolicyGraphEdgeCondition::Always,
    });
    let group = graph
        .groups
        .iter_mut()
        .find(|group| group.id == "workflow-entry")
        .expect("workflow entry group");
    group.node_ids.push("wait-checks".to_owned());
    group.frame.height = 360;
    graph.layout.nodes.push(PolicyGraphNodeLayout {
        node_id: "wait-checks".to_owned(),
        x: 24,
        y: 240,
    });
    graph
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

fn active_canvas(workspace: &PolicyCanvasWorkspace) -> &PolicyCanvasRecord {
    workspace
        .canvases
        .iter()
        .find(|canvas| canvas.id == workspace.active_canvas_id)
        .unwrap_or_else(|| panic!("missing active canvas {}", workspace.active_canvas_id))
}
