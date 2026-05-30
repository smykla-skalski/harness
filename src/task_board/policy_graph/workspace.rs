use std::path::PathBuf;

use chrono::Utc;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_json_typed;
use crate::infra::persistence::versioned_json::VersionedJsonRepository;

use super::store::PolicyPipelineSimulationResult;
use super::{POLICY_GRAPH_INITIAL_REVISION, PolicyGraph, PolicyGraphMode};

const POLICY_CANVAS_WORKSPACE_FILE: &str = "policy-canvases-v1.json";
const LEGACY_POLICY_PIPELINE_FILE: &str = "policy-pipeline-v2.json";
const LEGACY_POLICY_PIPELINE_SIMULATION_FILE: &str = "policy-pipeline-v2-simulation.json";
const POLICY_CANVAS_WORKSPACE_VERSION: u32 = 1;

pub const PRIMARY_POLICY_CANVAS_TITLE: &str = "Primary policy";
pub const REVIEW_TEXT_PASTE_DRY_RUN_CANVAS_TITLE: &str = "Pasted PR approvals (dry run)";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyCanvasRecord {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub updated_at: String,
    pub document: PolicyGraph,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest_simulation: Option<PolicyPipelineSimulationResult>,
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
}

impl PolicyCanvasWorkspace {
    #[must_use]
    pub fn seeded() -> Self {
        let primary =
            PolicyCanvasRecord::new(PRIMARY_POLICY_CANVAS_TITLE, PolicyGraph::seeded_v2(), None);
        let review_text_paste = PolicyCanvasRecord::new(
            REVIEW_TEXT_PASTE_DRY_RUN_CANVAS_TITLE,
            PolicyGraph::review_text_paste_dry_run_seeded_v2(),
            None,
        );
        Self {
            schema_version: POLICY_CANVAS_WORKSPACE_VERSION,
            active_canvas_id: review_text_paste.id.clone(),
            canvases: vec![primary, review_text_paste],
        }
    }

    #[must_use]
    pub fn from_legacy(
        document: PolicyGraph,
        latest_simulation: Option<PolicyPipelineSimulationResult>,
    ) -> Self {
        let primary =
            PolicyCanvasRecord::new(PRIMARY_POLICY_CANVAS_TITLE, document, latest_simulation);
        let review_text_paste = PolicyCanvasRecord::new(
            REVIEW_TEXT_PASTE_DRY_RUN_CANVAS_TITLE,
            PolicyGraph::review_text_paste_dry_run_seeded_v2(),
            None,
        );
        Self {
            schema_version: POLICY_CANVAS_WORKSPACE_VERSION,
            active_canvas_id: primary.id.clone(),
            canvases: vec![primary, review_text_paste],
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

    fn ensure_review_text_paste_dry_run_canvas(&mut self) -> bool {
        if self
            .canvases
            .iter()
            .any(|canvas| canvas.title == REVIEW_TEXT_PASTE_DRY_RUN_CANVAS_TITLE)
        {
            return false;
        }
        let should_activate = self.should_activate_review_text_paste_dry_run_seed();
        let review_text_paste = PolicyCanvasRecord::new(
            REVIEW_TEXT_PASTE_DRY_RUN_CANVAS_TITLE,
            PolicyGraph::review_text_paste_dry_run_seeded_v2(),
            None,
        );
        if should_activate {
            self.active_canvas_id = review_text_paste.id.clone();
        }
        self.canvases.push(review_text_paste);
        true
    }

    fn should_activate_review_text_paste_dry_run_seed(&self) -> bool {
        self.canvases.len() == 1
            && self
                .active_canvas()
                .is_some_and(is_unmodified_primary_policy_canvas)
    }
}

#[derive(Debug, Clone)]
pub struct PolicyCanvasWorkspaceStore {
    root: PathBuf,
}

impl PolicyCanvasWorkspaceStore {
    #[must_use]
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    /// Load durable canvas-library state, migrating legacy single-pipeline files
    /// when present and seeding a default canvas when absent.
    ///
    /// # Errors
    /// Returns `CliError` when canvas state cannot be loaded or migrated.
    pub fn load_or_seed(&self) -> Result<PolicyCanvasWorkspace, CliError> {
        self.migrate_legacy_files_if_needed()?;
        let repository = workspace_repository(self.root.clone());
        if let Some(mut workspace) = repository.load()? {
            if workspace.ensure_review_text_paste_dry_run_canvas() {
                repository.save(&workspace)?;
            }
            return Ok(workspace);
        }
        let workspace = PolicyCanvasWorkspace::seeded();
        repository.save(&workspace)?;
        Ok(workspace)
    }

    /// Load, mutate, and save the canvas workspace under the repository lock.
    ///
    /// # Errors
    /// Returns `CliError` when the workspace cannot be loaded or saved.
    pub fn update<F>(&self, update: F) -> Result<PolicyCanvasWorkspace, CliError>
    where
        F: FnOnce(&mut PolicyCanvasWorkspace) -> Result<(), CliError>,
    {
        self.migrate_legacy_files_if_needed()?;
        let repository = workspace_repository(self.root.clone());
        repository
            .update(|current| {
                let mut workspace = current.unwrap_or_else(PolicyCanvasWorkspace::seeded);
                workspace.ensure_review_text_paste_dry_run_canvas();
                update(&mut workspace)?;
                Ok(Some(workspace))
            })?
            .ok_or_else(|| {
                CliErrorKind::workflow_io("policy canvas workspace unexpectedly missing").into()
            })
    }

    fn migrate_legacy_files_if_needed(&self) -> Result<(), CliError> {
        let workspace_path = self.root.join(POLICY_CANVAS_WORKSPACE_FILE);
        if workspace_path.exists() {
            return Ok(());
        }
        let legacy_document_path = self.root.join(LEGACY_POLICY_PIPELINE_FILE);
        if !legacy_document_path.exists() {
            return Ok(());
        }
        let document: PolicyGraph = read_json_typed(&legacy_document_path)?;
        let legacy_simulation_path = self.root.join(LEGACY_POLICY_PIPELINE_SIMULATION_FILE);
        let latest_simulation = if legacy_simulation_path.exists() {
            Some(read_json_typed(&legacy_simulation_path)?)
        } else {
            None
        };
        let workspace = PolicyCanvasWorkspace::from_legacy(document, latest_simulation);
        workspace_repository(self.root.clone()).save(&workspace)?;
        Ok(())
    }
}

fn workspace_repository(root: PathBuf) -> VersionedJsonRepository<PolicyCanvasWorkspace> {
    VersionedJsonRepository::new(
        root.join(POLICY_CANVAS_WORKSPACE_FILE),
        POLICY_CANVAS_WORKSPACE_VERSION,
    )
}

fn is_unmodified_primary_policy_canvas(canvas: &PolicyCanvasRecord) -> bool {
    canvas.title == PRIMARY_POLICY_CANVAS_TITLE
        && canvas.document.revision == POLICY_GRAPH_INITIAL_REVISION
        && canvas.document.mode == PolicyGraphMode::Draft
        && canvas
            .document
            .policy_trace_ids
            .iter()
            .any(|trace_id| trace_id == "task-board-policy-graph-v2")
}
