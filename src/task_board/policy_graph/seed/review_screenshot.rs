use super::builders::{edge, group, layout, node, rect, strings};
use super::{
    POLICY_GRAPH_INITIAL_REVISION, POLICY_GRAPH_SCHEMA_VERSION, PORT_IMAGE, PORT_IN,
    PORT_PULL_REQUESTS, PORT_TEXT, PolicyActionStep, PolicyGraph, PolicyGraphAutomationBinding,
    PolicyGraphEdge, PolicyGraphEdgeCondition, PolicyGraphGroup, PolicyGraphLayout,
    PolicyGraphMode, PolicyGraphNode, PolicyGraphNodeKind, PolicyGraphNodeLayout,
    PolicyGraphOCRConfiguration, PolicyGraphReviewPullRequestExtraction,
};

const REVIEW_SCREENSHOT_GROUP_ID: &str = "automation:review-screenshot-extraction";
const REVIEW_SCREENSHOT_SOURCE_ID: &str = "automation:review-screenshot:source";
const REVIEW_SCREENSHOT_OCR_ID: &str = "automation:review-screenshot:ocr";
const REVIEW_SCREENSHOT_HUB_ID: &str = "automation:review-screenshot:hub";
const REVIEW_SCREENSHOT_RESOLVE_ID: &str = "automation:review-screenshot:resolve";
const REVIEW_SCREENSHOT_COPY_ID: &str = "automation:review-screenshot:copy";
const PORT_OUT_1: &str = "out_1";
const PORT_OUT_2: &str = "out_2";

pub(crate) fn review_screenshot_extraction_document() -> PolicyGraph {
    PolicyGraph {
        schema_version: POLICY_GRAPH_SCHEMA_VERSION,
        revision: POLICY_GRAPH_INITIAL_REVISION,
        mode: PolicyGraphMode::Draft,
        nodes: review_screenshot_nodes(),
        edges: review_screenshot_edges(),
        groups: vec![review_screenshot_group()],
        layout: PolicyGraphLayout {
            nodes: review_screenshot_layout(),
            ..PolicyGraphLayout::default()
        },
        policy_trace_ids: vec!["review-screenshot-extraction-canvas-v3".to_string()],
    }
}

fn review_screenshot_nodes() -> Vec<PolicyGraphNode> {
    let mut source = node(
        REVIEW_SCREENSHOT_SOURCE_ID,
        "Review Screenshot Paste",
        PolicyGraphNodeKind::ReviewScreenshotPaste,
        &[],
        &[PORT_IMAGE],
        REVIEW_SCREENSHOT_GROUP_ID,
    );
    source.automation = Some(review_screenshot_source_binding());

    let mut ocr = node(
        REVIEW_SCREENSHOT_OCR_ID,
        "OCR image",
        PolicyGraphNodeKind::OcrImage,
        &[PORT_IN],
        &[PORT_TEXT],
        REVIEW_SCREENSHOT_GROUP_ID,
    );
    ocr.automation = Some(review_screenshot_component_binding(&["ocrImage"]));

    let hub = node(
        REVIEW_SCREENSHOT_HUB_ID,
        "Hub",
        PolicyGraphNodeKind::Hub,
        &[PORT_IN],
        &[PORT_OUT_1, PORT_OUT_2],
        REVIEW_SCREENSHOT_GROUP_ID,
    );

    let mut resolve = node(
        REVIEW_SCREENSHOT_RESOLVE_ID,
        "Resolve Reviews PRs",
        PolicyGraphNodeKind::ResolveReviewPullRequests,
        &[PORT_IN],
        &[PORT_PULL_REQUESTS],
        REVIEW_SCREENSHOT_GROUP_ID,
    );
    resolve.automation = Some(review_screenshot_component_binding(&[
        "extractGitHubPullRequests",
        "resolveReviewPullRequests",
    ]));

    let mut copy = node(
        REVIEW_SCREENSHOT_COPY_ID,
        "Copy extracted PR URLs",
        PolicyGraphNodeKind::ActionStep(PolicyActionStep {
            action_id: "github.copy_extracted_pull_request_urls".to_string(),
        }),
        &[PORT_IN],
        &[],
        REVIEW_SCREENSHOT_GROUP_ID,
    );
    copy.automation = Some(review_screenshot_component_binding(&[
        "copyExtractedGitHubPullRequestURLs",
    ]));

    vec![source, ocr, hub, resolve, copy]
}

fn review_screenshot_edges() -> Vec<PolicyGraphEdge> {
    vec![
        edge(
            "edge:review-screenshot:ocr",
            REVIEW_SCREENSHOT_SOURCE_ID,
            PORT_IMAGE,
            REVIEW_SCREENSHOT_OCR_ID,
            PolicyGraphEdgeCondition::Always,
        ),
        edge(
            "edge:review-screenshot:hub",
            REVIEW_SCREENSHOT_OCR_ID,
            PORT_TEXT,
            REVIEW_SCREENSHOT_HUB_ID,
            PolicyGraphEdgeCondition::Always,
        ),
        edge(
            "edge:review-screenshot:resolve",
            REVIEW_SCREENSHOT_HUB_ID,
            PORT_OUT_1,
            REVIEW_SCREENSHOT_RESOLVE_ID,
            PolicyGraphEdgeCondition::Always,
        ),
        edge(
            "edge:review-screenshot:copy",
            REVIEW_SCREENSHOT_HUB_ID,
            PORT_OUT_2,
            REVIEW_SCREENSHOT_COPY_ID,
            PolicyGraphEdgeCondition::Always,
        ),
    ]
}

fn review_screenshot_group() -> PolicyGraphGroup {
    group(
        REVIEW_SCREENSHOT_GROUP_ID,
        "PR screenshot extraction",
        rect(36, 80, 1_040, 320),
        vec![
            REVIEW_SCREENSHOT_SOURCE_ID,
            REVIEW_SCREENSHOT_OCR_ID,
            REVIEW_SCREENSHOT_HUB_ID,
            REVIEW_SCREENSHOT_RESOLVE_ID,
            REVIEW_SCREENSHOT_COPY_ID,
        ],
    )
}

fn review_screenshot_layout() -> Vec<PolicyGraphNodeLayout> {
    vec![
        layout(REVIEW_SCREENSHOT_SOURCE_ID, 80, 180),
        layout(REVIEW_SCREENSHOT_OCR_ID, 320, 180),
        layout(REVIEW_SCREENSHOT_HUB_ID, 560, 180),
        layout(REVIEW_SCREENSHOT_RESOLVE_ID, 800, 120),
        layout(REVIEW_SCREENSHOT_COPY_ID, 800, 240),
    ]
}

fn review_screenshot_source_binding() -> PolicyGraphAutomationBinding {
    PolicyGraphAutomationBinding {
        is_enabled: true,
        event_source: "reviewScreenshotPaste".to_string(),
        priority: None,
        content_kinds: strings(&["image"]),
        preprocessors: strings(&[
            "dedupeByFingerprint",
            "normalizeGitHubPullRequestLinks",
            "dedupePullRequests",
        ]),
        actions: strings(&[
            "ocrImage",
            "extractGitHubPullRequests",
            "resolveReviewPullRequests",
            "copyExtractedGitHubPullRequestURLs",
            "recordMetadata",
        ]),
        postprocessors: strings(&["auditEvent"]),
        source_app_mode: "allExceptDenied".to_string(),
        allowed_bundle_identifiers: Vec::new(),
        denied_bundle_identifiers: Vec::new(),
        ocr_configuration: Some(PolicyGraphOCRConfiguration {
            recognition_level: "accurate".to_string(),
            automatically_detects_language: true,
            uses_language_correction: true,
        }),
        review_pull_request_extraction: Some(PolicyGraphReviewPullRequestExtraction {
            repository_mode: "allConfiguredRepos".to_string(),
            policy_repositories: Vec::new(),
            number_memory_enabled: true,
            result_scope: "all".to_string(),
            failure_signal_mode: "liveOrVisual".to_string(),
            output_format: "newlineGitHubURLs".to_string(),
            auto_copy: true,
            show_sheet: true,
        }),
    }
}

fn review_screenshot_component_binding(actions: &[&str]) -> PolicyGraphAutomationBinding {
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
