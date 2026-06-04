use std::collections::HashMap;

use serde_json::json;

use crate::errors::CliErrorKind;
use crate::task_board::policy::{
    BuiltInPolicyGate, PolicyAction, PolicyDecision, PolicyEvidence, PolicyGate, PolicyInput,
    PolicyReasonCode, PolicySubject,
};

use super::{
    DEFAULT_POLICY_CANVAS_TITLE, GraphPolicyGate, MANUAL_OCR_PASTE_CANVAS_TITLE, PORT_IN,
    PolicyCanvasRecord, PolicyCanvasRect, PolicyCanvasWorkspace, PolicyEvidencePredicate,
    PolicyGraph, PolicyGraphAutomationBinding, PolicyGraphEdge, PolicyGraphEdgeCondition,
    PolicyGraphGroup, PolicyGraphMode, PolicyGraphNode, PolicyGraphNodeKind, PolicyGraphNodeLayout,
    PolicyGraphOCRConfiguration, PolicyGraphReviewPullRequestExtraction,
    PolicyGraphValidationIssue, PolicyPipelinePromoteRequest, PolicyWaitCondition, PolicyWaitStep,
    PolicyWorkflowEntry, REVIEW_SCREENSHOT_EXTRACTION_CANVAS_TITLE,
    REVIEW_TEXT_PASTE_DRY_RUN_CANVAS_TITLE, apply_create, apply_delete, apply_duplicate,
    apply_import, apply_promote, apply_rename, apply_save_draft, apply_set_active, apply_simulate,
    apply_toggle_enforcement,
};

const NODE_WIDTH: i32 = 168;
const NODE_HEIGHT: i32 = 96;

#[path = "tests_workspace.rs"]
mod canvas_workspace;
#[path = "tests_hub.rs"]
mod hub_routing;
#[path = "tests_routing.rs"]
mod if_then_else_routing;
#[path = "tests_persistence.rs"]
mod persistence;
#[path = "tests_switch.rs"]
mod switch_routing;
#[path = "tests_workflow.rs"]
mod workflow_compile;

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
        ocr_configuration: Some(PolicyGraphOCRConfiguration {
            recognition_level: "fast".to_string(),
            automatically_detects_language: false,
            uses_language_correction: true,
        }),
        review_pull_request_extraction: Some(PolicyGraphReviewPullRequestExtraction {
            repository_mode: "policyRepositories".to_string(),
            policy_repositories: vec!["kong/kuma".to_string()],
            number_memory_enabled: true,
            result_scope: "failing".to_string(),
            failure_signal_mode: "visualScreenshot".to_string(),
            output_format: "markdownLinks".to_string(),
            auto_copy: false,
            show_sheet: true,
        }),
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
    assert_eq!(
        binding
            .ocr_configuration
            .as_ref()
            .expect("ocr config")
            .recognition_level,
        "fast"
    );
    assert_eq!(
        binding
            .review_pull_request_extraction
            .as_ref()
            .expect("review extraction config")
            .policy_repositories,
        vec!["kong/kuma".to_string()]
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
        PolicyInput::new(PolicyAction::MergePr)
            .with_evidence(if_then_else_routing::merge_evidence(false, false, 0)),
        PolicyInput::new(PolicyAction::MergePr)
            .with_evidence(if_then_else_routing::merge_evidence(true, true, 0)),
        PolicyInput::new(PolicyAction::MergePr)
            .with_evidence(if_then_else_routing::merge_evidence(true, false, 99)),
    ];

    for input in cases {
        assert_eq!(graph.evaluate(&input), builtin.evaluate(&input));
    }
}

#[test]
fn promotion_requires_exact_successful_simulation_revision() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let mut document = ws.active_canvas().unwrap().document.clone();
    document.nodes.iter_mut().for_each(|node| {
        if let PolicyGraphNodeKind::ActionGate { actions } = &mut node.kind {
            actions.retain(|action| *action != PolicyAction::DeleteWorktree);
        }
    });
    let saved = apply_save_draft(&mut ws, document, 0, None).expect("save draft");

    let failed = apply_promote(
        &mut ws,
        &PolicyPipelinePromoteRequest {
            revision: saved.document.revision,
            actor: None,
            canvas_id: None,
        },
    );
    assert!(failed.is_err());

    let simulation =
        apply_simulate(&mut ws, Some(saved.document.clone()), None).expect("simulate policy graph");
    assert!(simulation.succeeded);
    assert_eq!(simulation.revision, saved.document.revision);

    let promoted = apply_promote(
        &mut ws,
        &PolicyPipelinePromoteRequest {
            revision: saved.document.revision,
            actor: None,
            canvas_id: None,
        },
    )
    .expect("promote policy graph");

    assert_eq!(promoted.document.mode, PolicyGraphMode::Enforced);
    assert_eq!(promoted.document.revision, saved.document.revision);
}

#[test]
fn seeded_workspace_is_valid_and_contains_seeded_canvases() {
    let ws = PolicyCanvasWorkspace::seeded();
    assert_eq!(
        ws.canvases
            .iter()
            .map(|canvas| canvas.title.as_str())
            .collect::<Vec<_>>(),
        vec![
            DEFAULT_POLICY_CANVAS_TITLE,
            MANUAL_OCR_PASTE_CANVAS_TITLE,
            REVIEW_TEXT_PASTE_DRY_RUN_CANVAS_TITLE,
            REVIEW_SCREENSHOT_EXTRACTION_CANVAS_TITLE,
        ]
    );
    let active = ws.active_canvas().expect("active canvas");
    assert!(active.document.validate().is_valid());
    assert_eq!(active.document, PolicyGraph::seeded_v2());
    assert!(
        ws.canvases
            .iter()
            .find(|canvas| canvas.title == MANUAL_OCR_PASTE_CANVAS_TITLE)
            .expect("manual OCR paste canvas")
            .is_manual_ocr_paste_canvas
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
            source: None,
        },
        PolicyGraphNodeLayout {
            node_id: "entry-reviews-manual".to_owned(),
            x: 24,
            y: 132,
            source: None,
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
        source: None,
    });
    graph
}

fn active_canvas(workspace: &PolicyCanvasWorkspace) -> &PolicyCanvasRecord {
    workspace
        .canvases
        .iter()
        .find(|canvas| canvas.id == workspace.active_canvas_id)
        .unwrap_or_else(|| panic!("missing active canvas {}", workspace.active_canvas_id))
}
