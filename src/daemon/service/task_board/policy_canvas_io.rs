//! Import and export of whole policy-canvas documents.
//!
//! Export serializes the active (or a named) canvas so the caller can save it
//! as JSON; import validates an external document and creates a new active
//! canvas from it. Both reuse the workspace helpers in [`super::policy_canvas`].

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    TaskBoardPolicyExportRequest, TaskBoardPolicyExportResponse, TaskBoardPolicyImportRequest,
    TaskBoardPolicyImportResponse,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::policy_graph;

use super::policy_canvas::{bump_change_policy, feed_gate_cache, load_or_seed_workspace};
use super::policy_canvas_response::policy_canvas_workspace_response;

/// Serialize the active (or named) canvas document so the caller can save it
/// to disk as a JSON file.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be loaded or when the
/// requested canvas does not exist.
pub(crate) async fn export_task_board_policy(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyExportRequest,
) -> Result<TaskBoardPolicyExportResponse, CliError> {
    let workspace = load_or_seed_workspace(db).await?;
    let canvas = if let Some(canvas_id) = request.canvas_id.as_deref() {
        workspace.canvas(canvas_id).ok_or_else(|| {
            CliError::from(CliErrorKind::invalid_transition(format!(
                "unknown policy canvas '{canvas_id}'"
            )))
        })?
    } else {
        workspace.active_canvas().ok_or_else(|| {
            CliError::from(CliErrorKind::invalid_transition(
                "no active policy canvas".to_string(),
            ))
        })?
    };
    Ok(TaskBoardPolicyExportResponse {
        canvas_id: canvas.id.clone(),
        title: canvas.title.clone(),
        document: canvas.document.clone(),
    })
}

/// Import a policy graph document from an external JSON file, validate it, and
/// create a new canvas from it. The new canvas becomes active.
///
/// # Errors
/// Returns `CliError` when the document fails validation or the database
/// cannot be written.
pub(crate) async fn import_task_board_policy(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyImportRequest,
) -> Result<TaskBoardPolicyImportResponse, CliError> {
    let document = request.document.clone();
    let title = request.title.clone();
    let (workspace, _new_canvas) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
            policy_graph::apply_import(workspace, document, title)
        })
        .await?;
    feed_gate_cache(&workspace);
    bump_change_policy(db).await;
    Ok(policy_canvas_workspace_response(&workspace))
}
