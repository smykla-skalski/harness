use chrono::Utc;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::store::PolicyPipelineSimulationResult;
use super::{PolicyGraph, seed};

pub(crate) const POLICY_CANVAS_WORKSPACE_VERSION: u32 = 1;
pub const DEFAULT_POLICY_CANVAS_TITLE: &str = "Default";
pub const REVIEW_TEXT_PASTE_DRY_RUN_CANVAS_TITLE: &str = "Pasted PR approvals (dry run)";
const REVIEW_TEXT_PASTE_DRY_RUN_TRACE_ID: &str = "review-text-paste-dry-run-canvas-v1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyCanvasRecord {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub updated_at: String,
    pub document: PolicyGraph,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest_simulation: Option<PolicyPipelineSimulationResult>,
    #[serde(default)]
    pub is_review_text_paste_dry_run_canvas: bool,
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
            is_review_text_paste_dry_run_canvas: false,
        }
    }

    pub fn touch(&mut self) {
        self.updated_at = Utc::now().to_rfc3339();
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyCanvasWorkspace {
    pub schema_version: u32,
    pub active_canvas_id: String,
    #[serde(default)]
    pub canvases: Vec<PolicyCanvasRecord>,
    #[serde(default)]
    pub review_text_paste_dry_run_canvas_deleted: bool,
}

impl PolicyCanvasWorkspace {
    #[must_use]
    pub fn seeded() -> Self {
        let default_canvas =
            PolicyCanvasRecord::new(DEFAULT_POLICY_CANVAS_TITLE, PolicyGraph::seeded_v2(), None);
        let review_text_paste = review_text_paste_dry_run_canvas();
        Self {
            schema_version: POLICY_CANVAS_WORKSPACE_VERSION,
            active_canvas_id: default_canvas.id.clone(),
            canvases: vec![default_canvas, review_text_paste],
            review_text_paste_dry_run_canvas_deleted: false,
        }
    }

    #[must_use]
    pub fn from_legacy(
        document: PolicyGraph,
        latest_simulation: Option<PolicyPipelineSimulationResult>,
    ) -> Self {
        let default_canvas =
            PolicyCanvasRecord::new(DEFAULT_POLICY_CANVAS_TITLE, document, latest_simulation);
        let review_text_paste = review_text_paste_dry_run_canvas();
        Self {
            schema_version: POLICY_CANVAS_WORKSPACE_VERSION,
            active_canvas_id: default_canvas.id.clone(),
            canvases: vec![default_canvas, review_text_paste],
            review_text_paste_dry_run_canvas_deleted: false,
        }
    }

    #[must_use]
    pub fn active_canvas(&self) -> Option<&PolicyCanvasRecord> {
        self.canvases
            .iter()
            .find(|canvas| canvas.id == self.active_canvas_id)
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

    pub fn ensure_review_text_paste_dry_run_canvas(&mut self) -> bool {
        if let Some(canvas) = self
            .canvases
            .iter_mut()
            .find(|canvas| canvas.is_review_text_paste_dry_run_canvas)
        {
            return repair_legacy_composed_review_text_paste_canvas(canvas);
        }
        if let Some(canvas) = self
            .canvases
            .iter_mut()
            .find(|canvas| matches_review_text_paste_dry_run_canvas(canvas))
        {
            canvas.is_review_text_paste_dry_run_canvas = true;
            self.review_text_paste_dry_run_canvas_deleted = false;
            return repair_legacy_composed_review_text_paste_canvas(canvas) || true;
        }
        if self.review_text_paste_dry_run_canvas_deleted {
            return false;
        }
        self.canvases.push(review_text_paste_dry_run_canvas());
        true
    }
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

fn matches_review_text_paste_dry_run_canvas(canvas: &PolicyCanvasRecord) -> bool {
    canvas
        .document
        .policy_trace_ids
        .iter()
        .any(|trace_id| trace_id == REVIEW_TEXT_PASTE_DRY_RUN_TRACE_ID)
        || canvas.document == seed::legacy_composed_review_text_paste_dry_run_document()
}

fn repair_legacy_composed_review_text_paste_canvas(canvas: &mut PolicyCanvasRecord) -> bool {
    let mut repaired = false;
    if !canvas.is_review_text_paste_dry_run_canvas {
        canvas.is_review_text_paste_dry_run_canvas = true;
        repaired = true;
    }
    if canvas.document != seed::legacy_composed_review_text_paste_dry_run_document() {
        return repaired;
    }
    canvas.document = PolicyGraph::review_text_paste_dry_run_seeded_v2();
    canvas.latest_simulation = None;
    canvas.touch();
    true
}
