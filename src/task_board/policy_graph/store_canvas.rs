use uuid::Uuid;

use crate::errors::{CliError, CliErrorKind};

use super::{
    PolicyAction, PolicyCanvasRecord, PolicyCanvasWorkspace, PolicyGraph, PolicyGraphMode,
    PolicyGraphValidationReport, PolicyInput,
};

/// Import a canvas from an external policy graph document.
///
/// The document is validated before insertion. On success the new canvas becomes
/// the active canvas and is appended to the workspace.
///
/// # Errors
/// Returns `CliError` when the document fails validation.
pub fn apply_import(
    ws: &mut PolicyCanvasWorkspace,
    document: PolicyGraph,
    title: Option<String>,
) -> Result<PolicyCanvasRecord, CliError> {
    let report = document.validate();
    if !report.is_valid() {
        return Err(validation_error(&report));
    }
    let mut canvas = PolicyCanvasRecord::new(
        title.unwrap_or_else(|| "Imported policy".to_string()),
        document,
        None,
    );
    canvas.document.mode = PolicyGraphMode::Draft;
    ws.active_canvas_id.clone_from(&canvas.id);
    ws.canvases.push(canvas.clone());
    Ok(canvas)
}

/// Duplicate an existing canvas into a new draft canvas.
///
/// # Errors
/// Returns `CliError` when the source canvas cannot be found.
pub fn apply_duplicate(
    ws: &mut PolicyCanvasWorkspace,
    source_canvas_id: &str,
    title: Option<String>,
) -> Result<PolicyCanvasRecord, CliError> {
    let Some(source) = ws.canvas(source_canvas_id).cloned() else {
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
    let created = canvas.clone();
    ws.canvases.push(canvas);
    Ok(created)
}

/// Create a brand-new seeded draft canvas and make it active.
///
/// # Errors
/// Returns `CliError` when the workspace cannot be updated.
pub fn apply_create(
    ws: &mut PolicyCanvasWorkspace,
    title: Option<String>,
) -> Result<PolicyCanvasRecord, CliError> {
    let canvas = PolicyCanvasRecord::new(
        title.unwrap_or_else(|| "New policy".to_string()),
        PolicyGraph::seeded_v2(),
        None,
    );
    ws.active_canvas_id.clone_from(&canvas.id);
    ws.canvases.push(canvas.clone());
    Ok(canvas)
}

/// Switch the active canvas used by compatibility policy operations.
///
/// # Errors
/// Returns `CliError` when the target canvas cannot be found.
pub fn apply_set_active(ws: &mut PolicyCanvasWorkspace, canvas_id: &str) -> Result<(), CliError> {
    if ws.canvas(canvas_id).is_none() {
        return Err(CliErrorKind::invalid_transition(format!(
            "unknown policy canvas '{canvas_id}'"
        ))
        .into());
    }
    ws.active_canvas_id = canvas_id.to_string();
    Ok(())
}

/// Set global policy enforcement without changing any canvas document.
pub fn apply_set_global_enforcement(ws: &mut PolicyCanvasWorkspace, enabled: bool) -> bool {
    ws.global_policy_enforcement_enabled = enabled;
    ws.global_policy_enforcement_enabled
}

/// Delete a canvas while preserving at least one remaining canvas.
///
/// # Errors
/// Returns `CliError` when the target canvas cannot be found or when the caller
/// attempts to delete the last remaining canvas.
pub fn apply_delete(ws: &mut PolicyCanvasWorkspace, canvas_id: &str) -> Result<(), CliError> {
    let Some(index) = ws.canvases.iter().position(|canvas| canvas.id == canvas_id) else {
        return Err(CliErrorKind::invalid_transition(format!(
            "unknown policy canvas '{canvas_id}'"
        ))
        .into());
    };
    if ws.canvases.len() == 1 {
        return Err(
            CliErrorKind::invalid_transition("cannot delete the last canvas".to_string()).into(),
        );
    }
    let was_manual_ocr = ws.canvases[index].is_manual_ocr_paste_canvas;
    let was_dry_run = ws.canvases[index].is_review_text_paste_dry_run_canvas;
    let was_screenshot_extraction = ws.canvases[index].is_review_screenshot_extraction_canvas;
    ws.canvases.remove(index);
    if was_manual_ocr {
        ws.manual_ocr_paste_canvas_deleted = true;
    }
    if was_dry_run {
        ws.review_text_paste_dry_run_canvas_deleted = true;
    }
    if was_screenshot_extraction {
        ws.review_screenshot_extraction_canvas_deleted = true;
    }
    if ws.active_canvas_id == canvas_id
        && let Some(next_active) = ws.canvases.first()
    {
        ws.active_canvas_id = next_active.id.clone();
    }
    Ok(())
}

/// Rename an existing canvas without mutating its document.
///
/// # Errors
/// Returns `CliError` when the target canvas cannot be found.
pub fn apply_rename(
    ws: &mut PolicyCanvasWorkspace,
    canvas_id: &str,
    title: impl Into<String>,
) -> Result<(), CliError> {
    let title = title.into();
    let Some(canvas) = ws.canvases.iter_mut().find(|canvas| canvas.id == canvas_id) else {
        return Err(CliErrorKind::invalid_transition(format!(
            "unknown policy canvas '{canvas_id}'"
        ))
        .into());
    };
    canvas.title = title;
    canvas.touch();
    Ok(())
}

pub(crate) fn validation_error(report: &PolicyGraphValidationReport) -> CliError {
    CliErrorKind::invalid_transition(format!(
        "policy graph validation failed with {} issue(s)",
        report.issues.len()
    ))
    .into()
}

pub(crate) fn new_trace_id() -> String {
    format!("policy-pipeline-{}", Uuid::new_v4().simple())
}

pub(crate) fn simulation_inputs() -> Vec<PolicyInput> {
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
            evaluated_at: None,
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
