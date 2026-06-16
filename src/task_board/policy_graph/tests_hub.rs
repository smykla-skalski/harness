use super::*;
use crate::task_board::policy_graph::{
    POLICY_GRAPH_INITIAL_REVISION, POLICY_GRAPH_SCHEMA_VERSION, PORT_IMAGE, PORT_TEXT,
    PolicyActionStep, PolicyGraphLayout,
};

#[test]
fn hub_validation_rejects_incompatible_fanout_payload() {
    let mut graph = manual_ocr_hub_graph();
    graph.nodes.push(PolicyGraphNode {
        id: "review-sink".into(),
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
        input_ports: vec![PORT_IN.into()],
        output_ports: Vec::new(),
        group_id: None,
    });
    graph.edges.push(PolicyGraphEdge {
        id: "edge:hub-review-sink".into(),
        from_node: "hub".into(),
        from_port: "out_3".into(),
        to_node: "review-sink".into(),
        to_port: PORT_IN.into(),
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
                id: "source".into(),
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
                output_ports: vec![PORT_IMAGE.into()],
                group_id: None,
            },
            PolicyGraphNode {
                id: "ocr".into(),
                label: "OCR image".to_owned(),
                kind: PolicyGraphNodeKind::OcrImage,
                automation: None,
                input_ports: vec![PORT_IN.into()],
                output_ports: vec![PORT_TEXT.into()],
                group_id: None,
            },
            PolicyGraphNode {
                id: "hub".into(),
                label: "Hub".to_owned(),
                kind: PolicyGraphNodeKind::Hub,
                automation: None,
                input_ports: vec![PORT_IN.into()],
                output_ports: vec!["out_1".into(), "out_2".into(), "out_3".into()],
                group_id: None,
            },
            PolicyGraphNode {
                id: "debug".into(),
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
                input_ports: vec![PORT_IN.into()],
                output_ports: Vec::new(),
                group_id: None,
            },
            PolicyGraphNode {
                id: "persist".into(),
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
                input_ports: vec![PORT_IN.into()],
                output_ports: Vec::new(),
                group_id: None,
            },
        ],
        edges: vec![
            PolicyGraphEdge {
                id: "edge:source-ocr".into(),
                from_node: "source".into(),
                from_port: PORT_IMAGE.into(),
                to_node: "ocr".into(),
                to_port: PORT_IN.into(),
                label: None,
                condition: PolicyGraphEdgeCondition::Always,
            },
            PolicyGraphEdge {
                id: "edge:ocr-hub".into(),
                from_node: "ocr".into(),
                from_port: PORT_TEXT.into(),
                to_node: "hub".into(),
                to_port: PORT_IN.into(),
                label: None,
                condition: PolicyGraphEdgeCondition::Always,
            },
            PolicyGraphEdge {
                id: "edge:hub-debug".into(),
                from_node: "hub".into(),
                from_port: "out_1".into(),
                to_node: "debug".into(),
                to_port: PORT_IN.into(),
                label: None,
                condition: PolicyGraphEdgeCondition::Always,
            },
            PolicyGraphEdge {
                id: "edge:hub-persist".into(),
                from_node: "hub".into(),
                from_port: "out_2".into(),
                to_node: "persist".into(),
                to_port: PORT_IN.into(),
                label: None,
                condition: PolicyGraphEdgeCondition::Always,
            },
        ],
        groups: Vec::new(),
        layout: PolicyGraphLayout::default(),
        policy_trace_ids: vec!["manual-ocr-hub-test".to_owned()],
    }
}
