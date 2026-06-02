use super::{
    POLICY_GRAPH_INITIAL_REVISION, POLICY_GRAPH_SCHEMA_VERSION, PORT_IMAGE, PORT_IN,
    PORT_PULL_REQUESTS, PORT_TEXT, PolicyGraph, PolicyGraphAutomationBinding, PolicyGraphEdge,
    PolicyGraphEdgeCondition, PolicyGraphGroup, PolicyGraphLayout, PolicyGraphMode,
    PolicyGraphNode, PolicyGraphNodeKind, PolicyGraphNodeLayout, PolicyGraphOCRConfiguration,
    PolicyGraphReviewPullRequestExtraction, edge, group, layout, node, rect, strings,
};

const REVIEW_SCREENSHOT_GROUP_ID: &str = "automation:review-screenshot-extraction";
const REVIEW_SCREENSHOT_SOURCE_ID: &str = "automation:review-screenshot:source";
const REVIEW_SCREENSHOT_OCR_ID: &str = "automation:review-screenshot:ocr";
const REVIEW_SCREENSHOT_RESOLVE_ID: &str = "automation:review-screenshot:resolve";
const REVIEW_SCREENSHOT_COPY_ID: &str = "automation:review-screenshot:copy";

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
        },
        policy_trace_ids: vec!["review-screenshot-extraction-canvas-v2".to_string()],
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
        "OCR screenshot rows",
        PolicyGraphNodeKind::OcrImage,
        &[PORT_IN],
        &[PORT_TEXT],
        REVIEW_SCREENSHOT_GROUP_ID,
    );
    ocr.automation = Some(review_screenshot_component_binding(&["ocrImage"]));

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
        "Copy PR list",
        PolicyGraphNodeKind::CopyReviewPullRequestList,
        &[PORT_IN],
        &[],
        REVIEW_SCREENSHOT_GROUP_ID,
    );
    copy.automation = Some(review_screenshot_component_binding(&[
        "copyReviewPullRequestList",
        "previewReviewApprovals",
    ]));

    vec![source, ocr, resolve, copy]
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
            "edge:review-screenshot:resolve",
            REVIEW_SCREENSHOT_OCR_ID,
            PORT_TEXT,
            REVIEW_SCREENSHOT_RESOLVE_ID,
            PolicyGraphEdgeCondition::Always,
        ),
        edge(
            "edge:review-screenshot:copy",
            REVIEW_SCREENSHOT_RESOLVE_ID,
            PORT_PULL_REQUESTS,
            REVIEW_SCREENSHOT_COPY_ID,
            PolicyGraphEdgeCondition::Always,
        ),
    ]
}

fn review_screenshot_group() -> PolicyGraphGroup {
    group(
        REVIEW_SCREENSHOT_GROUP_ID,
        "PR screenshot extraction",
        rect(36, 80, 1_040, 220),
        vec![
            REVIEW_SCREENSHOT_SOURCE_ID,
            REVIEW_SCREENSHOT_OCR_ID,
            REVIEW_SCREENSHOT_RESOLVE_ID,
            REVIEW_SCREENSHOT_COPY_ID,
        ],
    )
}

fn review_screenshot_layout() -> Vec<PolicyGraphNodeLayout> {
    vec![
        layout(REVIEW_SCREENSHOT_SOURCE_ID, 80, 140),
        layout(REVIEW_SCREENSHOT_OCR_ID, 320, 140),
        layout(REVIEW_SCREENSHOT_RESOLVE_ID, 560, 140),
        layout(REVIEW_SCREENSHOT_COPY_ID, 800, 140),
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
            "copyReviewPullRequestList",
            "previewReviewApprovals",
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
