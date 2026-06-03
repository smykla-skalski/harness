use super::{
    POLICY_GRAPH_INITIAL_REVISION, POLICY_GRAPH_SCHEMA_VERSION, PORT_IMAGE, PORT_IN, PORT_TEXT,
    PolicyActionStep, PolicyGraph, PolicyGraphAutomationBinding, PolicyGraphEdge,
    PolicyGraphEdgeCondition, PolicyGraphGroup, PolicyGraphLayout, PolicyGraphMode,
    PolicyGraphNode, PolicyGraphNodeKind, PolicyGraphNodeLayout, edge, group, layout, node, rect,
    strings,
};

const MANUAL_OCR_GROUP_ID: &str = "automation:manual-ocr-paste";
const MANUAL_OCR_SOURCE_ID: &str = "automation:manual-ocr-paste:source";
const MANUAL_OCR_OCR_ID: &str = "automation:manual-ocr-paste:ocr";
const MANUAL_OCR_HUB_ID: &str = "automation:manual-ocr-paste:hub";
const MANUAL_OCR_DEBUG_ID: &str = "automation:manual-ocr-paste:debug";
const MANUAL_OCR_PERSIST_ID: &str = "automation:manual-ocr-paste:persist";
const PORT_OUT_1: &str = "out_1";
const PORT_OUT_2: &str = "out_2";

pub(crate) fn manual_ocr_paste_document() -> PolicyGraph {
    PolicyGraph {
        schema_version: POLICY_GRAPH_SCHEMA_VERSION,
        revision: POLICY_GRAPH_INITIAL_REVISION,
        mode: PolicyGraphMode::Enforced,
        nodes: manual_ocr_nodes(),
        edges: manual_ocr_edges(),
        groups: vec![manual_ocr_group()],
        layout: PolicyGraphLayout {
            nodes: manual_ocr_layout(),
            ..PolicyGraphLayout::default()
        },
        policy_trace_ids: vec!["manual-ocr-paste-canvas-v1".to_string()],
    }
}

fn manual_ocr_nodes() -> Vec<PolicyGraphNode> {
    let mut source = node(
        MANUAL_OCR_SOURCE_ID,
        "Manual OCR Paste",
        PolicyGraphNodeKind::ActionStep(PolicyActionStep {
            action_id: "automation.manual_ocr_paste".to_string(),
        }),
        &[],
        &[PORT_IMAGE],
        MANUAL_OCR_GROUP_ID,
    );
    source.automation = Some(manual_ocr_source_binding());

    let mut ocr = node(
        MANUAL_OCR_OCR_ID,
        "OCR image",
        PolicyGraphNodeKind::OcrImage,
        &[PORT_IN],
        &[PORT_TEXT],
        MANUAL_OCR_GROUP_ID,
    );
    ocr.automation = Some(manual_ocr_component_binding(&["ocrImage"], &[]));

    let hub = node(
        MANUAL_OCR_HUB_ID,
        "Hub",
        PolicyGraphNodeKind::Hub,
        &[PORT_IN],
        &[PORT_OUT_1, PORT_OUT_2],
        MANUAL_OCR_GROUP_ID,
    );

    let mut debug = node(
        MANUAL_OCR_DEBUG_ID,
        "Open Debugging",
        PolicyGraphNodeKind::ActionStep(PolicyActionStep {
            action_id: "dashboard.open_debugging".to_string(),
        }),
        &[PORT_IN],
        &[],
        MANUAL_OCR_GROUP_ID,
    );
    debug.automation = Some(manual_ocr_component_binding(
        &["openDashboardDebugging"],
        &[],
    ));

    let mut persist = node(
        MANUAL_OCR_PERSIST_ID,
        "Persist OCR result",
        PolicyGraphNodeKind::ActionStep(PolicyActionStep {
            action_id: "ocr.persist_result".to_string(),
        }),
        &[PORT_IN],
        &[],
        MANUAL_OCR_GROUP_ID,
    );
    persist.automation = Some(manual_ocr_component_binding(
        &["rememberRecentScan", "showFeedback", "recordMetadata"],
        &["sourceSpecificTextCleanup", "persistResult", "auditEvent"],
    ));

    vec![source, ocr, hub, debug, persist]
}

fn manual_ocr_edges() -> Vec<PolicyGraphEdge> {
    vec![
        edge(
            "edge:manual-ocr-paste:ocr",
            MANUAL_OCR_SOURCE_ID,
            PORT_IMAGE,
            MANUAL_OCR_OCR_ID,
            PolicyGraphEdgeCondition::Always,
        ),
        edge(
            "edge:manual-ocr-paste:hub",
            MANUAL_OCR_OCR_ID,
            PORT_TEXT,
            MANUAL_OCR_HUB_ID,
            PolicyGraphEdgeCondition::Always,
        ),
        edge(
            "edge:manual-ocr-paste:debug",
            MANUAL_OCR_HUB_ID,
            PORT_OUT_1,
            MANUAL_OCR_DEBUG_ID,
            PolicyGraphEdgeCondition::Always,
        ),
        edge(
            "edge:manual-ocr-paste:persist",
            MANUAL_OCR_HUB_ID,
            PORT_OUT_2,
            MANUAL_OCR_PERSIST_ID,
            PolicyGraphEdgeCondition::Always,
        ),
    ]
}

fn manual_ocr_group() -> PolicyGraphGroup {
    group(
        MANUAL_OCR_GROUP_ID,
        "Manual OCR Paste",
        rect(36, 80, 1_040, 220),
        vec![
            MANUAL_OCR_SOURCE_ID,
            MANUAL_OCR_OCR_ID,
            MANUAL_OCR_HUB_ID,
            MANUAL_OCR_DEBUG_ID,
            MANUAL_OCR_PERSIST_ID,
        ],
    )
}

fn manual_ocr_layout() -> Vec<PolicyGraphNodeLayout> {
    vec![
        layout(MANUAL_OCR_SOURCE_ID, 80, 140),
        layout(MANUAL_OCR_OCR_ID, 320, 140),
        layout(MANUAL_OCR_HUB_ID, 560, 140),
        layout(MANUAL_OCR_DEBUG_ID, 800, 88),
        layout(MANUAL_OCR_PERSIST_ID, 800, 192),
    ]
}

fn manual_ocr_source_binding() -> PolicyGraphAutomationBinding {
    PolicyGraphAutomationBinding {
        is_enabled: true,
        event_source: "manualOCRPaste".to_string(),
        priority: None,
        content_kinds: strings(&["image"]),
        preprocessors: strings(&["dedupeByFingerprint"]),
        actions: Vec::new(),
        postprocessors: Vec::new(),
        source_app_mode: "allExceptDenied".to_string(),
        allowed_bundle_identifiers: Vec::new(),
        denied_bundle_identifiers: Vec::new(),
        ocr_configuration: None,
        review_pull_request_extraction: None,
    }
}

fn manual_ocr_component_binding(
    actions: &[&str],
    postprocessors: &[&str],
) -> PolicyGraphAutomationBinding {
    PolicyGraphAutomationBinding {
        is_enabled: true,
        event_source: "clipboard".to_string(),
        priority: None,
        content_kinds: Vec::new(),
        preprocessors: Vec::new(),
        actions: strings(actions),
        postprocessors: strings(postprocessors),
        source_app_mode: "allExceptDenied".to_string(),
        allowed_bundle_identifiers: Vec::new(),
        denied_bundle_identifiers: Vec::new(),
        ocr_configuration: None,
        review_pull_request_extraction: None,
    }
}
