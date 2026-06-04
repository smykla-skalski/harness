use super::*;
use crate::task_board::policy_graph::{
    POLICY_GRAPH_INITIAL_REVISION, POLICY_GRAPH_SCHEMA_VERSION, PORT_IMAGE, PORT_TEXT,
    PolicyActionStep, PolicyGraphLayout,
};

#[test]
fn hub_validation_rejects_incompatible_fanout_payload() {
    let mut graph = manual_ocr_hub_graph();
    graph.nodes.push(PolicyGraphNode {
        id: "review-sink".to_owned(),
        label: "Copy PR list".to_owned(),
        kind: PolicyGraphNodeKind::CopyReviewPullRequestList,
        automation: Some(PolicyGraphAutomationBinding {
            is_enabled: true,
            event_source: "manualOCRPaste".to_owned(),
            priority: None,
            content_kinds: Vec::new(),
            preprocessors: Vec::new(),
            actions: vec!["copyReviewPullRequestList".to_owned()],
            postprocessors: Vec::new(),
            source_app_mode: "allExceptDenied".to_owned(),
            allowed_bundle_identifiers: Vec::new(),
            denied_bundle_identifiers: Vec::new(),
            ocr_configuration: None,
            review_pull_request_extraction: None,
        }),
        input_ports: vec![PORT_IN.to_owned()],
        output_ports: Vec::new(),
        group_id: None,
    });
    graph.edges.push(PolicyGraphEdge {
        id: "edge:hub-review-sink".to_owned(),
        from_node: "hub".to_owned(),
        from_port: "out_3".to_owned(),
        to_node: "review-sink".to_owned(),
        to_port: PORT_IN.to_owned(),
        label: None,
        condition: PolicyGraphEdgeCondition::Always,
    });

    let report = graph.validate();

    assert!(
        report.issues.iter().any(|issue| matches!(
            issue,
            PolicyGraphValidationIssue::IncompatiblePayloadEdge {
                edge_id,
                provided,
                required,
            } if edge_id == "edge:hub-review-sink"
                && provided == "text"
                && required == "pull_requests"
        )),
        "Hub must reject text fan-out into pull-request consumer: {:?}",
        report.issues
    );
}

#[test]
fn hub_simulation_visits_all_compatible_fanout_branches() {
    let graph = manual_ocr_hub_graph();

    assert!(graph.validate().is_valid(), "Hub graph should validate");

    let result = graph.simulate(&PolicyInput::new(PolicyAction::Sync));

    assert!(
        result
            .visited_node_ids
            .windows(5)
            .any(|window| window == ["source", "ocr", "hub", "debug", "persist"]),
        "simulation should visit every Hub branch in deterministic order: {:?}",
        result.visited_node_ids
    );
}

fn manual_ocr_hub_graph() -> PolicyGraph {
    PolicyGraph {
        schema_version: POLICY_GRAPH_SCHEMA_VERSION,
        revision: POLICY_GRAPH_INITIAL_REVISION,
        mode: PolicyGraphMode::Enforced,
        nodes: vec![
            PolicyGraphNode {
                id: "source".to_owned(),
                label: "Manual OCR Paste".to_owned(),
                kind: PolicyGraphNodeKind::ActionStep(PolicyActionStep {
                    action_id: "automation.manual_ocr_paste".to_owned(),
                }),
                automation: Some(PolicyGraphAutomationBinding {
                    is_enabled: true,
                    event_source: "manualOCRPaste".to_owned(),
                    priority: None,
                    content_kinds: vec![PORT_IMAGE.to_owned()],
                    preprocessors: Vec::new(),
                    actions: Vec::new(),
                    postprocessors: Vec::new(),
                    source_app_mode: "allExceptDenied".to_owned(),
                    allowed_bundle_identifiers: Vec::new(),
                    denied_bundle_identifiers: Vec::new(),
                    ocr_configuration: None,
                    review_pull_request_extraction: None,
                }),
                input_ports: Vec::new(),
                output_ports: vec![PORT_IMAGE.to_owned()],
                group_id: None,
            },
            PolicyGraphNode {
                id: "ocr".to_owned(),
                label: "OCR image".to_owned(),
                kind: PolicyGraphNodeKind::OcrImage,
                automation: None,
                input_ports: vec![PORT_IN.to_owned()],
                output_ports: vec![PORT_TEXT.to_owned()],
                group_id: None,
            },
            PolicyGraphNode {
                id: "hub".to_owned(),
                label: "Hub".to_owned(),
                kind: PolicyGraphNodeKind::Hub,
                automation: None,
                input_ports: vec![PORT_IN.to_owned()],
                output_ports: vec!["out_1".to_owned(), "out_2".to_owned(), "out_3".to_owned()],
                group_id: None,
            },
            PolicyGraphNode {
                id: "debug".to_owned(),
                label: "Open Debugging".to_owned(),
                kind: PolicyGraphNodeKind::ActionStep(PolicyActionStep {
                    action_id: "dashboard.open_debugging".to_owned(),
                }),
                automation: Some(PolicyGraphAutomationBinding {
                    is_enabled: true,
                    event_source: "manualOCRPaste".to_owned(),
                    priority: None,
                    content_kinds: Vec::new(),
                    preprocessors: Vec::new(),
                    actions: vec!["openDashboardDebugging".to_owned()],
                    postprocessors: Vec::new(),
                    source_app_mode: "allExceptDenied".to_owned(),
                    allowed_bundle_identifiers: Vec::new(),
                    denied_bundle_identifiers: Vec::new(),
                    ocr_configuration: None,
                    review_pull_request_extraction: None,
                }),
                input_ports: vec![PORT_IN.to_owned()],
                output_ports: Vec::new(),
                group_id: None,
            },
            PolicyGraphNode {
                id: "persist".to_owned(),
                label: "Persist OCR result".to_owned(),
                kind: PolicyGraphNodeKind::ActionStep(PolicyActionStep {
                    action_id: "ocr.persist_result".to_owned(),
                }),
                automation: Some(PolicyGraphAutomationBinding {
                    is_enabled: true,
                    event_source: "manualOCRPaste".to_owned(),
                    priority: None,
                    content_kinds: Vec::new(),
                    preprocessors: Vec::new(),
                    actions: vec![
                        "rememberRecentScan".to_owned(),
                        "showFeedback".to_owned(),
                        "recordMetadata".to_owned(),
                    ],
                    postprocessors: vec![
                        "sourceSpecificTextCleanup".to_owned(),
                        "persistResult".to_owned(),
                        "auditEvent".to_owned(),
                    ],
                    source_app_mode: "allExceptDenied".to_owned(),
                    allowed_bundle_identifiers: Vec::new(),
                    denied_bundle_identifiers: Vec::new(),
                    ocr_configuration: None,
                    review_pull_request_extraction: None,
                }),
                input_ports: vec![PORT_IN.to_owned()],
                output_ports: Vec::new(),
                group_id: None,
            },
        ],
        edges: vec![
            PolicyGraphEdge {
                id: "edge:source-ocr".to_owned(),
                from_node: "source".to_owned(),
                from_port: PORT_IMAGE.to_owned(),
                to_node: "ocr".to_owned(),
                to_port: PORT_IN.to_owned(),
                label: None,
                condition: PolicyGraphEdgeCondition::Always,
            },
            PolicyGraphEdge {
                id: "edge:ocr-hub".to_owned(),
                from_node: "ocr".to_owned(),
                from_port: PORT_TEXT.to_owned(),
                to_node: "hub".to_owned(),
                to_port: PORT_IN.to_owned(),
                label: None,
                condition: PolicyGraphEdgeCondition::Always,
            },
            PolicyGraphEdge {
                id: "edge:hub-debug".to_owned(),
                from_node: "hub".to_owned(),
                from_port: "out_1".to_owned(),
                to_node: "debug".to_owned(),
                to_port: PORT_IN.to_owned(),
                label: None,
                condition: PolicyGraphEdgeCondition::Always,
            },
            PolicyGraphEdge {
                id: "edge:hub-persist".to_owned(),
                from_node: "hub".to_owned(),
                from_port: "out_2".to_owned(),
                to_node: "persist".to_owned(),
                to_port: PORT_IN.to_owned(),
                label: None,
                condition: PolicyGraphEdgeCondition::Always,
            },
        ],
        groups: Vec::new(),
        layout: PolicyGraphLayout::default(),
        policy_trace_ids: vec!["manual-ocr-hub-test".to_owned()],
    }
}
