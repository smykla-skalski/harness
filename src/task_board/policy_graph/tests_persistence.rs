use super::*;
use crate::task_board::policy_graph::{
    REVIEW_SCREENSHOT_EXTRACTION_CANVAS_TITLE, REVIEW_TEXT_PASTE_DRY_RUN_CANVAS_TITLE,
};

#[test]
fn save_draft_rejects_stale_revision() {
    let mut ws = PolicyCanvasWorkspace::seeded();
    let seeded = ws.active_canvas().unwrap().document.clone();
    let baseline_revision = seeded.revision;
    let first = apply_save_draft(&mut ws, seeded.clone(), baseline_revision, None)
        .expect("save first draft");
    assert!(first.persisted, "valid draft must persist");

    let stale_attempt = apply_save_draft(&mut ws, seeded, baseline_revision, None);
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
    let mut ws = PolicyCanvasWorkspace::seeded();
    let baseline = ws.active_canvas().unwrap().document.clone();
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

    let response = apply_save_draft(&mut ws, invalid, 0, None).expect("save returns response");
    assert!(!response.persisted, "invalid drafts must not persist");
    assert!(
        !response.validation.is_valid(),
        "validation must surface issues for invalid drafts",
    );

    let on_disk = ws.active_canvas().unwrap().document.clone();
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
fn from_legacy_migrates_pipeline_document_into_canvas_workspace() {
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

    let workspace =
        PolicyCanvasWorkspace::from_legacy(legacy_document.clone(), Some(legacy_simulation));

    assert_eq!(
        workspace.canvases.len(),
        3,
        "legacy state should preserve the migrated canvas and add seeded review canvases"
    );
    let active = active_canvas(&workspace);
    assert_eq!(active.title, "Default");
    assert_eq!(active.document, legacy_document);
    assert_eq!(
        active
            .latest_simulation
            .as_ref()
            .map(|simulation| simulation.trace_id.as_str()),
        Some("legacy-simulation"),
    );
    let review_text_paste = workspace
        .canvases
        .iter()
        .find(|canvas| canvas.title == REVIEW_TEXT_PASTE_DRY_RUN_CANVAS_TITLE)
        .expect("review text paste dry-run canvas");
    assert_review_text_paste_canvas_only(review_text_paste);
    let review_screenshot = workspace
        .canvases
        .iter()
        .find(|canvas| canvas.title == REVIEW_SCREENSHOT_EXTRACTION_CANVAS_TITLE)
        .expect("review screenshot extraction canvas");
    assert_review_screenshot_canvas_only(review_screenshot);
}

#[test]
fn seeded_workspace_adds_review_canvases_without_activating_them() {
    let workspace = PolicyCanvasWorkspace::seeded();

    assert_eq!(workspace.canvases.len(), 3);
    let default_canvas = workspace
        .canvases
        .iter()
        .find(|canvas| canvas.title == "Default")
        .expect("default canvas");
    assert_eq!(
        default_canvas.id, workspace.active_canvas_id,
        "the default canvas remains active for task-board compatibility"
    );
    assert_eq!(
        default_canvas.document,
        PolicyGraph::seeded_v2(),
        "default canvas should remain the unchanged task-board policy seed"
    );
    assert!(
        default_canvas
            .document
            .nodes
            .iter()
            .all(|node| node
                .automation
                .as_ref()
                .is_none_or(
                    |automation| automation.event_source != "manualReviewTextPaste"
                        && automation.event_source != "reviewScreenshotPaste"
                )),
        "default canvas must not receive Reviews automation policies"
    );
    let review_text_paste = workspace
        .canvases
        .iter()
        .find(|canvas| canvas.title == REVIEW_TEXT_PASTE_DRY_RUN_CANVAS_TITLE)
        .expect("review text paste dry-run canvas");
    assert_ne!(review_text_paste.id, workspace.active_canvas_id);
    assert_review_text_paste_canvas_only(review_text_paste);
    let review_screenshot = workspace
        .canvases
        .iter()
        .find(|canvas| canvas.title == REVIEW_SCREENSHOT_EXTRACTION_CANVAS_TITLE)
        .expect("review screenshot extraction canvas");
    assert_ne!(review_screenshot.id, workspace.active_canvas_id);
    assert_review_screenshot_canvas_only(review_screenshot);
}

#[test]
fn ensure_dry_run_canvas_repairs_legacy_composed_review_text_paste_canvas() {
    let mut workspace = PolicyCanvasWorkspace::seeded();
    let review_text_paste = workspace
        .canvases
        .iter_mut()
        .find(|canvas| canvas.title == REVIEW_TEXT_PASTE_DRY_RUN_CANVAS_TITLE)
        .expect("review text paste dry-run canvas");
    review_text_paste.document =
        crate::task_board::policy_graph::seed::legacy_composed_review_text_paste_dry_run_document();

    let repaired = workspace.ensure_review_text_paste_dry_run_canvas();
    assert!(repaired, "legacy composed document should trigger repair");

    let review_text_paste = workspace
        .canvases
        .iter()
        .find(|canvas| canvas.title == REVIEW_TEXT_PASTE_DRY_RUN_CANVAS_TITLE)
        .expect("review text paste dry-run canvas");
    assert_review_text_paste_canvas_only(review_text_paste);
}

fn assert_review_text_paste_canvas_only(canvas: &PolicyCanvasRecord) {
    assert_eq!(canvas.document.mode, PolicyGraphMode::Enforced);
    assert!(
        canvas.document.validate().is_valid(),
        "review text paste canvas should be valid"
    );
    assert_eq!(
        canvas.document.nodes.len(),
        4,
        "review text paste canvas should contain only the pasted-PR workflow"
    );
    assert!(
        canvas
            .document
            .nodes
            .iter()
            .all(|node| !node.id.starts_with("action:")),
        "review text paste canvas must not embed the default task-board graph"
    );
    assert!(
        !canvas
            .document
            .policy_trace_ids
            .iter()
            .any(|trace_id| trace_id == "task-board-policy-graph-v2"),
        "review text paste canvas must not carry the default graph trace"
    );
    assert!(
        canvas.document.nodes.iter().any(|node| node
            .automation
            .as_ref()
            .is_some_and(|automation| automation.event_source == "manualReviewTextPaste")),
        "review text paste canvas should carry the manual text paste automation binding"
    );
    assert!(
        canvas
            .document
            .nodes
            .iter()
            .any(|node| matches!(node.kind, PolicyGraphNodeKind::DryRunGate { .. })),
        "review text paste canvas should route to a generic dry-run gate"
    );
}

fn assert_review_screenshot_canvas_only(canvas: &PolicyCanvasRecord) {
    assert_eq!(canvas.document.mode, PolicyGraphMode::Enforced);
    assert!(
        canvas.document.validate().is_valid(),
        "review screenshot canvas should be valid"
    );
    assert_eq!(
        canvas.document.nodes.len(),
        4,
        "review screenshot canvas should contain only the screenshot extraction workflow"
    );
    assert!(
        canvas
            .document
            .nodes
            .iter()
            .all(|node| !node.id.starts_with("action:")),
        "review screenshot canvas must not embed the default task-board graph"
    );
    assert!(
        canvas.document.nodes.iter().any(|node| node
            .automation
            .as_ref()
            .is_some_and(|automation| automation.event_source == "reviewScreenshotPaste")),
        "review screenshot canvas should carry the screenshot paste automation binding"
    );
    let source = canvas
        .document
        .nodes
        .iter()
        .find_map(|node| node.automation.as_ref())
        .expect("automation binding");
    assert!(
        source.ocr_configuration.is_some(),
        "review screenshot canvas should configure OCR"
    );
    assert!(
        source.review_pull_request_extraction.is_some(),
        "review screenshot canvas should configure PR extraction"
    );
}
