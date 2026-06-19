use chrono::Utc;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::scenario::{PolicyScenario, default_seeded_scenarios};
use super::store::PolicyPipelineSimulationResult;
use super::{
    PORT_IMAGE, PORT_IN, PORT_PULL_REQUESTS, PORT_TEXT, PolicyGraph, PolicyGraphEdgeCondition,
    PolicyGraphMode, PolicyGraphNode, PolicyGraphNodeKind,
};

pub(crate) const POLICY_CANVAS_WORKSPACE_VERSION: u32 = 1;
pub const DEFAULT_POLICY_CANVAS_TITLE: &str = "Default";
pub const MANUAL_OCR_PASTE_CANVAS_TITLE: &str = "Manual OCR Paste";
pub const REVIEW_TEXT_PASTE_DRY_RUN_CANVAS_TITLE: &str = "Pasted PR approvals (dry run)";
pub const REVIEW_SCREENSHOT_EXTRACTION_CANVAS_TITLE: &str = "PR screenshot extraction";
const MANUAL_OCR_PASTE_TRACE_ID: &str = "manual-ocr-paste-canvas-v1";
const REVIEW_TEXT_PASTE_DRY_RUN_TRACE_ID: &str = "review-text-paste-dry-run-canvas-v1";
const REVIEW_SCREENSHOT_EXTRACTION_TRACE_ID: &str = "review-screenshot-extraction-canvas-v3";
const LEGACY_REVIEW_SCREENSHOT_EXTRACTION_TRACE_ID: &str = "review-screenshot-extraction-canvas-v2";
const REVIEW_SCREENSHOT_SOURCE_ID: &str = "automation:review-screenshot:source";
const REVIEW_SCREENSHOT_OCR_ID: &str = "automation:review-screenshot:ocr";
const REVIEW_SCREENSHOT_RESOLVE_ID: &str = "automation:review-screenshot:resolve";
const REVIEW_SCREENSHOT_COPY_ID: &str = "automation:review-screenshot:copy";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PolicyCanvasRecord {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub updated_at: String,
    pub document: PolicyGraph,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest_simulation: Option<PolicyPipelineSimulationResult>,
    #[serde(default)]
    pub is_manual_ocr_paste_canvas: bool,
    #[serde(default)]
    pub is_review_text_paste_dry_run_canvas: bool,
    #[serde(default)]
    pub is_review_screenshot_extraction_canvas: bool,
}

impl PolicyCanvasRecord {
    #[must_use]
    pub fn new(
        title: impl Into<String>,
        document: PolicyGraph,
        latest_simulation: Option<PolicyPipelineSimulationResult>,
    ) -> Self {
        let now = Utc::now().to_rfc3339();
        Self {
            id: format!("policy-canvas-{}", Uuid::new_v4().simple()),
            title: title.into(),
            created_at: now.clone(),
            updated_at: now,
            document,
            latest_simulation,
            is_manual_ocr_paste_canvas: false,
            is_review_text_paste_dry_run_canvas: false,
            is_review_screenshot_extraction_canvas: false,
        }
    }

    pub fn touch(&mut self) {
        self.updated_at = Utc::now().to_rfc3339();
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PolicyCanvasWorkspace {
    pub schema_version: u32,
    pub active_canvas_id: String,
    #[serde(default)]
    pub canvases: Vec<PolicyCanvasRecord>,
    #[serde(default = "default_global_policy_enforcement_enabled")]
    pub global_policy_enforcement_enabled: bool,
    #[serde(default)]
    pub manual_ocr_paste_canvas_deleted: bool,
    #[serde(default)]
    pub review_text_paste_dry_run_canvas_deleted: bool,
    #[serde(default)]
    pub review_screenshot_extraction_canvas_deleted: bool,
    #[serde(default)]
    pub scenarios: Vec<PolicyScenario>,
    #[serde(default)]
    pub scenarios_seeded: bool,
}

impl PolicyCanvasWorkspace {
    #[must_use]
    pub fn seeded() -> Self {
        let default_canvas =
            PolicyCanvasRecord::new(DEFAULT_POLICY_CANVAS_TITLE, PolicyGraph::seeded_v2(), None);
        let manual_ocr_paste = manual_ocr_paste_canvas();
        let review_text_paste = review_text_paste_dry_run_canvas();
        let review_screenshot = review_screenshot_extraction_canvas();
        Self {
            schema_version: POLICY_CANVAS_WORKSPACE_VERSION,
            active_canvas_id: default_canvas.id.clone(),
            canvases: vec![
                default_canvas,
                manual_ocr_paste,
                review_text_paste,
                review_screenshot,
            ],
            global_policy_enforcement_enabled: true,
            manual_ocr_paste_canvas_deleted: false,
            review_text_paste_dry_run_canvas_deleted: false,
            review_screenshot_extraction_canvas_deleted: false,
            scenarios: default_seeded_scenarios(),
            scenarios_seeded: true,
        }
    }

    #[must_use]
    pub fn active_canvas(&self) -> Option<&PolicyCanvasRecord> {
        self.canvases
            .iter()
            .find(|canvas| canvas.id == self.active_canvas_id)
    }

    #[must_use]
    pub fn active_enforced_canvas(&self) -> Option<&PolicyCanvasRecord> {
        if !self.global_policy_enforcement_enabled {
            return None;
        }
        self.active_canvas()
            .filter(|canvas| canvas.document.mode == PolicyGraphMode::Enforced)
    }

    pub fn active_canvas_mut(&mut self) -> Option<&mut PolicyCanvasRecord> {
        self.canvases
            .iter_mut()
            .find(|canvas| canvas.id == self.active_canvas_id)
    }

    #[must_use]
    pub fn canvas(&self, canvas_id: &str) -> Option<&PolicyCanvasRecord> {
        self.canvases.iter().find(|canvas| canvas.id == canvas_id)
    }

    pub fn ensure_manual_ocr_paste_canvas(&mut self) -> bool {
        if self
            .canvases
            .iter()
            .any(|canvas| canvas.is_manual_ocr_paste_canvas)
        {
            return false;
        }
        if let Some(canvas) = self
            .canvases
            .iter_mut()
            .find(|canvas| matches_manual_ocr_paste_canvas(canvas))
        {
            canvas.is_manual_ocr_paste_canvas = true;
            self.manual_ocr_paste_canvas_deleted = false;
            return true;
        }
        if self.manual_ocr_paste_canvas_deleted {
            return false;
        }
        self.canvases.push(manual_ocr_paste_canvas());
        true
    }

    pub fn ensure_review_text_paste_dry_run_canvas(&mut self) -> bool {
        if self
            .canvases
            .iter()
            .any(|canvas| canvas.is_review_text_paste_dry_run_canvas)
        {
            return false;
        }
        if let Some(canvas) = self
            .canvases
            .iter_mut()
            .find(|canvas| matches_review_text_paste_dry_run_canvas(canvas))
        {
            canvas.is_review_text_paste_dry_run_canvas = true;
            self.review_text_paste_dry_run_canvas_deleted = false;
            return true;
        }
        if self.review_text_paste_dry_run_canvas_deleted {
            return false;
        }
        self.canvases.push(review_text_paste_dry_run_canvas());
        true
    }

    pub fn ensure_review_screenshot_extraction_canvas(&mut self) -> bool {
        if let Some(canvas) = self
            .canvases
            .iter_mut()
            .find(|canvas| canvas.is_review_screenshot_extraction_canvas)
        {
            return repair_review_screenshot_extraction_canvas(canvas);
        }
        if let Some(canvas) = self
            .canvases
            .iter_mut()
            .find(|canvas| matches_review_screenshot_extraction_canvas(canvas))
        {
            canvas.is_review_screenshot_extraction_canvas = true;
            self.review_screenshot_extraction_canvas_deleted = false;
            repair_review_screenshot_extraction_canvas(canvas);
            return true;
        }
        if self.review_screenshot_extraction_canvas_deleted {
            return false;
        }
        self.canvases.push(review_screenshot_extraction_canvas());
        true
    }

    pub fn ensure_seeded_automation_canvases(&mut self) -> bool {
        let repaired_manual_ocr = self.ensure_manual_ocr_paste_canvas();
        let repaired_text_paste = self.ensure_review_text_paste_dry_run_canvas();
        let repaired_screenshot = self.ensure_review_screenshot_extraction_canvas();
        repaired_manual_ocr || repaired_text_paste || repaired_screenshot
    }

    /// Seed the default scenario set exactly once. Workspaces predating scenarios
    /// load with `scenarios_seeded == false`; the first call fills the baseline
    /// and flips the guard so later deletions are not resurrected on reload.
    pub fn ensure_seeded_scenarios(&mut self) -> bool {
        if self.scenarios_seeded {
            return false;
        }
        self.scenarios_seeded = true;
        if self.scenarios.is_empty() {
            self.scenarios = default_seeded_scenarios();
        }
        true
    }
}

const fn default_global_policy_enforcement_enabled() -> bool {
    true
}

fn manual_ocr_paste_canvas() -> PolicyCanvasRecord {
    let mut canvas = PolicyCanvasRecord::new(
        MANUAL_OCR_PASTE_CANVAS_TITLE,
        PolicyGraph::manual_ocr_paste_seeded_v2(),
        None,
    );
    canvas.is_manual_ocr_paste_canvas = true;
    canvas
}

fn review_text_paste_dry_run_canvas() -> PolicyCanvasRecord {
    let mut canvas = PolicyCanvasRecord::new(
        REVIEW_TEXT_PASTE_DRY_RUN_CANVAS_TITLE,
        PolicyGraph::review_text_paste_dry_run_seeded_v2(),
        None,
    );
    canvas.is_review_text_paste_dry_run_canvas = true;
    canvas
}

fn review_screenshot_extraction_canvas() -> PolicyCanvasRecord {
    let mut canvas = PolicyCanvasRecord::new(
        REVIEW_SCREENSHOT_EXTRACTION_CANVAS_TITLE,
        PolicyGraph::review_screenshot_extraction_seeded_v2(),
        None,
    );
    canvas.is_review_screenshot_extraction_canvas = true;
    canvas
}

fn matches_manual_ocr_paste_canvas(canvas: &PolicyCanvasRecord) -> bool {
    canvas
        .document
        .policy_trace_ids
        .iter()
        .any(|trace_id| trace_id == MANUAL_OCR_PASTE_TRACE_ID)
}

fn matches_review_text_paste_dry_run_canvas(canvas: &PolicyCanvasRecord) -> bool {
    canvas
        .document
        .policy_trace_ids
        .iter()
        .any(|trace_id| trace_id == REVIEW_TEXT_PASTE_DRY_RUN_TRACE_ID)
}

fn matches_review_screenshot_extraction_canvas(canvas: &PolicyCanvasRecord) -> bool {
    document_has_trace_id(&canvas.document, REVIEW_SCREENSHOT_EXTRACTION_TRACE_ID)
        || is_canonical_legacy_review_screenshot_extraction_canvas(canvas)
}

fn repair_review_screenshot_extraction_canvas(canvas: &mut PolicyCanvasRecord) -> bool {
    let mut changed = false;
    if !canvas.is_review_screenshot_extraction_canvas {
        canvas.is_review_screenshot_extraction_canvas = true;
        changed = true;
    }
    if !document_has_trace_id(&canvas.document, REVIEW_SCREENSHOT_EXTRACTION_TRACE_ID)
        && is_canonical_legacy_review_screenshot_extraction_canvas(canvas)
    {
        canvas.document = PolicyGraph::review_screenshot_extraction_seeded_v2();
        canvas.latest_simulation = None;
        canvas.touch();
        changed = true;
    }
    changed
}

fn is_canonical_legacy_review_screenshot_extraction_canvas(canvas: &PolicyCanvasRecord) -> bool {
    let document = &canvas.document;
    if !document_has_trace_id(document, LEGACY_REVIEW_SCREENSHOT_EXTRACTION_TRACE_ID)
        || document_has_trace_id(document, REVIEW_SCREENSHOT_EXTRACTION_TRACE_ID)
        || document.nodes.len() != 4
        || document.edges.len() != 3
    {
        return false;
    }

    let Some(source) = node(document, REVIEW_SCREENSHOT_SOURCE_ID) else {
        return false;
    };
    let Some(ocr) = node(document, REVIEW_SCREENSHOT_OCR_ID) else {
        return false;
    };
    let Some(resolve) = node(document, REVIEW_SCREENSHOT_RESOLVE_ID) else {
        return false;
    };
    let Some(copy) = node(document, REVIEW_SCREENSHOT_COPY_ID) else {
        return false;
    };

    matches!(source.kind, PolicyGraphNodeKind::ReviewScreenshotPaste)
        && matches!(ocr.kind, PolicyGraphNodeKind::OcrImage)
        && matches!(resolve.kind, PolicyGraphNodeKind::ResolveReviewPullRequests)
        && matches!(copy.kind, PolicyGraphNodeKind::CopyReviewPullRequestList)
        && automation_actions(
            source,
            &[
                "ocrImage",
                "extractGitHubPullRequests",
                "resolveReviewPullRequests",
                "copyReviewPullRequestList",
                "previewReviewApprovals",
                "recordMetadata",
            ],
        )
        && automation_actions(ocr, &["ocrImage"])
        && automation_actions(
            resolve,
            &["extractGitHubPullRequests", "resolveReviewPullRequests"],
        )
        && automation_actions(
            copy,
            &["copyReviewPullRequestList", "previewReviewApprovals"],
        )
        && has_edge(
            document,
            "edge:review-screenshot:ocr",
            REVIEW_SCREENSHOT_SOURCE_ID,
            PORT_IMAGE,
            REVIEW_SCREENSHOT_OCR_ID,
            PORT_IN,
        )
        && has_edge(
            document,
            "edge:review-screenshot:resolve",
            REVIEW_SCREENSHOT_OCR_ID,
            PORT_TEXT,
            REVIEW_SCREENSHOT_RESOLVE_ID,
            PORT_IN,
        )
        && has_edge(
            document,
            "edge:review-screenshot:copy",
            REVIEW_SCREENSHOT_RESOLVE_ID,
            PORT_PULL_REQUESTS,
            REVIEW_SCREENSHOT_COPY_ID,
            PORT_IN,
        )
}

fn document_has_trace_id(document: &PolicyGraph, trace_id: &str) -> bool {
    document
        .policy_trace_ids
        .iter()
        .any(|candidate| candidate == trace_id)
}

fn node<'a>(document: &'a PolicyGraph, node_id: &str) -> Option<&'a PolicyGraphNode> {
    document.nodes.iter().find(|node| node.id == node_id)
}

fn automation_actions(node: &PolicyGraphNode, actions: &[&str]) -> bool {
    node.automation.as_ref().is_some_and(|automation| {
        automation.actions.len() == actions.len()
            && automation
                .actions
                .iter()
                .zip(actions)
                .all(|(left, right)| left == right)
    })
}

fn has_edge(
    document: &PolicyGraph,
    edge_id: &str,
    from_node: &str,
    from_port: &str,
    to_node: &str,
    to_port: &str,
) -> bool {
    document.edges.iter().any(|edge| {
        edge.id == edge_id
            && edge.from_node == from_node
            && edge.from_port == from_port
            && edge.to_node == to_node
            && edge.to_port == to_port
            && edge.condition == PolicyGraphEdgeCondition::Always
    })
}
