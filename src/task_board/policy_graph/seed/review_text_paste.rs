use super::{
    POLICY_GRAPH_INITIAL_REVISION, POLICY_GRAPH_SCHEMA_VERSION, PORT_DEFAULT, PORT_IN,
    PolicyActionStep, PolicyGraph, PolicyGraphAutomationBinding, PolicyGraphEdge,
    PolicyGraphEdgeCondition, PolicyGraphGroup, PolicyGraphLayout, PolicyGraphMode,
    PolicyGraphNode, PolicyGraphNodeKind, PolicyGraphNodeLayout, PolicyReasonCode, edge, group,
    layout, node, rect, strings,
};

const REVIEW_TEXT_PASTE_GROUP_ID: &str = "automation:review-text-paste";
const REVIEW_TEXT_PASTE_SOURCE_ID: &str = "automation:review-text-paste:source";
const REVIEW_TEXT_PASTE_PREVIEW_ID: &str = "automation:review-text-paste:preview";
const REVIEW_TEXT_PASTE_PROMPT_ID: &str = "automation:review-text-paste:prompt";
const REVIEW_TEXT_PASTE_DRY_RUN_ID: &str = "automation:review-text-paste:dry-run";

pub(crate) fn review_text_paste_dry_run_document() -> PolicyGraph {
    PolicyGraph {
        schema_version: POLICY_GRAPH_SCHEMA_VERSION,
        revision: POLICY_GRAPH_INITIAL_REVISION,
        mode: PolicyGraphMode::Enforced,
        nodes: review_text_paste_nodes(),
        edges: review_text_paste_edges(),
        groups: vec![review_text_paste_group()],
        layout: PolicyGraphLayout {
            nodes: review_text_paste_layout(),
        },
        policy_trace_ids: vec!["review-text-paste-dry-run-canvas-v1".to_string()],
    }
}

fn review_text_paste_nodes() -> Vec<PolicyGraphNode> {
    let mut source = node(
        REVIEW_TEXT_PASTE_SOURCE_ID,
        "Review Text Paste",
        PolicyGraphNodeKind::ActionStep(PolicyActionStep {
            action_id: "automation.review_text_paste".to_string(),
        }),
        &[],
        &[PORT_DEFAULT],
        REVIEW_TEXT_PASTE_GROUP_ID,
    );
    source.automation = Some(review_text_paste_source_binding());

    let mut preview = node(
        REVIEW_TEXT_PASTE_PREVIEW_ID,
        "Show PR detail cards",
        PolicyGraphNodeKind::ActionStep(PolicyActionStep {
            action_id: "reviews.preview_approvals".to_string(),
        }),
        &[PORT_IN],
        &[PORT_DEFAULT],
        REVIEW_TEXT_PASTE_GROUP_ID,
    );
    preview.automation = Some(review_text_paste_component_binding(&[
        "previewReviewApprovals",
    ]));

    let mut prompt = node(
        REVIEW_TEXT_PASTE_PROMPT_ID,
        "Prompt before approval",
        PolicyGraphNodeKind::ActionStep(PolicyActionStep {
            action_id: "reviews.prompt_approvals".to_string(),
        }),
        &[PORT_IN],
        &[PORT_DEFAULT],
        REVIEW_TEXT_PASTE_GROUP_ID,
    );
    prompt.automation = Some(review_text_paste_component_binding(&[
        "promptReviewApprovals",
    ]));

    let dry_run = node(
        REVIEW_TEXT_PASTE_DRY_RUN_ID,
        "Dry-run gate",
        PolicyGraphNodeKind::DryRunGate {
            reason_code: PolicyReasonCode::DryRunRequired,
        },
        &[PORT_IN],
        &[],
        REVIEW_TEXT_PASTE_GROUP_ID,
    );

    vec![source, preview, prompt, dry_run]
}

fn review_text_paste_edges() -> Vec<PolicyGraphEdge> {
    vec![
        edge(
            "edge:review-text-paste:preview",
            REVIEW_TEXT_PASTE_SOURCE_ID,
            PORT_DEFAULT,
            REVIEW_TEXT_PASTE_PREVIEW_ID,
            PolicyGraphEdgeCondition::Always,
        ),
        edge(
            "edge:review-text-paste:prompt",
            REVIEW_TEXT_PASTE_PREVIEW_ID,
            PORT_DEFAULT,
            REVIEW_TEXT_PASTE_PROMPT_ID,
            PolicyGraphEdgeCondition::Always,
        ),
        edge(
            "edge:review-text-paste:dry-run",
            REVIEW_TEXT_PASTE_PROMPT_ID,
            PORT_DEFAULT,
            REVIEW_TEXT_PASTE_DRY_RUN_ID,
            PolicyGraphEdgeCondition::Always,
        ),
    ]
}

fn review_text_paste_group() -> PolicyGraphGroup {
    group(
        REVIEW_TEXT_PASTE_GROUP_ID,
        "Pasted PR approvals",
        rect(36, 80, 1_040, 220),
        vec![
            REVIEW_TEXT_PASTE_SOURCE_ID,
            REVIEW_TEXT_PASTE_PREVIEW_ID,
            REVIEW_TEXT_PASTE_PROMPT_ID,
            REVIEW_TEXT_PASTE_DRY_RUN_ID,
        ],
    )
}

fn review_text_paste_layout() -> Vec<PolicyGraphNodeLayout> {
    vec![
        layout(REVIEW_TEXT_PASTE_SOURCE_ID, 80, 140),
        layout(REVIEW_TEXT_PASTE_PREVIEW_ID, 320, 140),
        layout(REVIEW_TEXT_PASTE_PROMPT_ID, 560, 140),
        layout(REVIEW_TEXT_PASTE_DRY_RUN_ID, 800, 140),
    ]
}

fn review_text_paste_source_binding() -> PolicyGraphAutomationBinding {
    PolicyGraphAutomationBinding {
        is_enabled: true,
        event_source: "manualReviewTextPaste".to_string(),
        priority: None,
        content_kinds: strings(&["text", "url"]),
        preprocessors: strings(&["normalizeGitHubPullRequestLinks", "dedupePullRequests"]),
        actions: strings(&[
            "extractGitHubPullRequests",
            "previewReviewApprovals",
            "promptReviewApprovals",
            "recordMetadata",
        ]),
        postprocessors: strings(&["auditEvent"]),
        source_app_mode: "allExceptDenied".to_string(),
        allowed_bundle_identifiers: Vec::new(),
        denied_bundle_identifiers: Vec::new(),
        ocr_configuration: None,
        review_pull_request_extraction: None,
    }
}

fn review_text_paste_component_binding(actions: &[&str]) -> PolicyGraphAutomationBinding {
    PolicyGraphAutomationBinding {
        is_enabled: true,
        event_source: "clipboard".to_string(),
        priority: None,
        content_kinds: Vec::new(),
        preprocessors: Vec::new(),
        actions: strings(actions),
        postprocessors: Vec::new(),
        source_app_mode: "allExceptDenied".to_string(),
        allowed_bundle_identifiers: Vec::new(),
        denied_bundle_identifiers: Vec::new(),
        ocr_configuration: None,
        review_pull_request_extraction: None,
    }
}
