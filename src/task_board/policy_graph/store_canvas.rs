use uuid::Uuid;

use crate::errors::{CliError, CliErrorKind};

use super::{
    PolicyAction, PolicyCanvasRecord, PolicyCanvasWorkspace, PolicyGraph, PolicyGraphMode,
    PolicyGraphValidationReport, PolicyInput,
};

use super::store::PolicyPipelineStore;

impl PolicyPipelineStore {
    /// Duplicate an existing canvas into a new draft canvas.
    ///
    /// # Errors
    /// Returns `CliError` when the source canvas cannot be found or the
    /// workspace cannot be updated.
    pub fn duplicate_canvas(
        &self,
        source_canvas_id: &str,
        title: Option<String>,
    ) -> Result<PolicyCanvasRecord, CliError> {
        let mut duplicated = None;
        let source_canvas_id = source_canvas_id.to_string();
        self.workspace_store().update(|workspace| {
            let Some(source) = workspace.canvas(&source_canvas_id).cloned() else {
                return Err(CliErrorKind::invalid_transition(format!(
                    "unknown policy canvas '{source_canvas_id}'"
                ))
                .into());
            };
            let mut canvas = PolicyCanvasRecord::new(
                title.unwrap_or_else(|| format!("{} copy", source.title)),
                source.document,
                source.latest_simulation,
            );
            canvas.document.mode = PolicyGraphMode::Draft;
            duplicated = Some(canvas.clone());
            workspace.canvases.push(canvas);
            Ok(())
        })?;
        duplicated.ok_or_else(|| {
            CliErrorKind::workflow_io("policy canvas duplication did not produce a canvas").into()
        })
    }

    /// Create a brand-new seeded draft canvas and make it active.
    ///
    /// # Errors
    /// Returns `CliError` when the workspace cannot be updated.
    pub fn create_canvas(&self, title: Option<String>) -> Result<PolicyCanvasRecord, CliError> {
        let mut created = None;
        self.workspace_store().update(|workspace| {
            let canvas = PolicyCanvasRecord::new(
                title.unwrap_or_else(|| "New policy".to_string()),
                PolicyGraph::seeded_v2(),
                None,
            );
            workspace.active_canvas_id.clone_from(&canvas.id);
            workspace.canvases.push(canvas.clone());
            created = Some(canvas);
            Ok(())
        })?;
        created.ok_or_else(|| {
            CliErrorKind::workflow_io("policy canvas creation did not produce a canvas").into()
        })
    }

    /// Switch the active canvas used by compatibility policy operations.
    ///
    /// # Errors
    /// Returns `CliError` when the target canvas cannot be found.
    pub fn set_active_canvas(&self, canvas_id: &str) -> Result<PolicyCanvasWorkspace, CliError> {
        let canvas_id = canvas_id.to_string();
        self.workspace_store().update(|workspace| {
            if workspace.canvas(&canvas_id).is_none() {
                return Err(CliErrorKind::invalid_transition(format!(
                    "unknown policy canvas '{canvas_id}'"
                ))
                .into());
            }
            workspace.active_canvas_id.clone_from(&canvas_id);
            Ok(())
        })
    }

    /// Delete a canvas while preserving at least one remaining canvas.
    ///
    /// # Errors
    /// Returns `CliError` when the target canvas cannot be found or when the
    /// caller attempts to delete the last remaining canvas.
    pub fn delete_canvas(&self, canvas_id: &str) -> Result<PolicyCanvasWorkspace, CliError> {
        let canvas_id = canvas_id.to_string();
        self.workspace_store().update(|workspace| {
            let Some(index) = workspace
                .canvases
                .iter()
                .position(|canvas| canvas.id == canvas_id)
            else {
                return Err(CliErrorKind::invalid_transition(format!(
                    "unknown policy canvas '{canvas_id}'"
                ))
                .into());
            };
            if workspace.canvases.len() == 1 {
                return Err(CliErrorKind::invalid_transition(
                    "cannot delete the last canvas".to_string(),
                )
                .into());
            }
            workspace.canvases.remove(index);
            if workspace.active_canvas_id == canvas_id
                && let Some(next_active) = workspace.canvases.first()
            {
                workspace.active_canvas_id = next_active.id.clone();
            }
            Ok(())
        })
    }

    /// Rename an existing canvas without mutating its document.
    ///
    /// # Errors
    /// Returns `CliError` when the target canvas cannot be found.
    pub fn rename_canvas(
        &self,
        canvas_id: &str,
        title: impl Into<String>,
    ) -> Result<PolicyCanvasWorkspace, CliError> {
        let canvas_id = canvas_id.to_string();
        let title = title.into();
        self.workspace_store().update(|workspace| {
            let Some(canvas) = workspace
                .canvases
                .iter_mut()
                .find(|canvas| canvas.id == canvas_id)
            else {
                return Err(CliErrorKind::invalid_transition(format!(
                    "unknown policy canvas '{canvas_id}'"
                ))
                .into());
            };
            canvas.title.clone_from(&title);
            canvas.touch();
            Ok(())
        })
    }
}

pub(super) fn validation_error(report: &PolicyGraphValidationReport) -> CliError {
    CliErrorKind::invalid_transition(format!(
        "policy graph validation failed with {} issue(s)",
        report.issues.len()
    ))
    .into()
}

pub(super) fn new_trace_id() -> String {
    format!("policy-pipeline-{}", Uuid::new_v4().simple())
}

pub(super) fn simulation_inputs() -> Vec<PolicyInput> {
    use crate::task_board::policy::{
        DEFAULT_AUTO_MERGE_RISK_THRESHOLD, PolicyEvidence, PolicySubject,
    };

    let default_subject = PolicySubject::default();
    let merge_evidence = PolicyEvidence {
        checks_green: Some(true),
        branch_protection_allows_merge: Some(true),
        reviewer_verdict_approved: Some(true),
        unresolved_requested_changes: Some(0),
        protected_path_touched: Some(false),
        risk_score: Some(DEFAULT_AUTO_MERGE_RISK_THRESHOLD),
        ..PolicyEvidence::default()
    };
    all_actions()
        .into_iter()
        .map(|action| PolicyInput {
            workflow: None,
            action,
            subject: default_subject.clone(),
            evidence: if action == PolicyAction::MergePr {
                merge_evidence.clone()
            } else {
                PolicyEvidence::default()
            },
        })
        .collect()
}

fn all_actions() -> Vec<PolicyAction> {
    vec![
        PolicyAction::Sync,
        PolicyAction::Triage,
        PolicyAction::Plan,
        PolicyAction::SpawnAgent,
        PolicyAction::MutateRepo,
        PolicyAction::PushBranch,
        PolicyAction::OpenPr,
        PolicyAction::SubmitReview,
        PolicyAction::MergePr,
        PolicyAction::DeleteWorktree,
        PolicyAction::StopAgent,
        PolicyAction::AccessSecret,
        PolicyAction::DestructiveFs,
    ]
}
