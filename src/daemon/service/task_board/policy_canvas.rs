use std::ffi::OsString;
use std::fs;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    TaskBoardPolicyCanvasCreateRequest, TaskBoardPolicyCanvasDeleteRequest,
    TaskBoardPolicyCanvasDuplicateRequest, TaskBoardPolicyCanvasRenameRequest,
    TaskBoardPolicyCanvasSetActiveRequest, TaskBoardPolicyCanvasSummary,
    TaskBoardPolicyCanvasToggleEnforcementRequest, TaskBoardPolicyCanvasWorkspaceResponse,
    TaskBoardPolicyExportRequest, TaskBoardPolicyExportResponse, TaskBoardPolicyImportRequest,
    TaskBoardPolicyImportResponse, TaskBoardPolicyPipelineAuditRequest,
    TaskBoardPolicyPipelineAuditResponse, TaskBoardPolicyPipelineGetRequest,
    TaskBoardPolicyPipelinePromoteRequest, TaskBoardPolicyPipelinePromoteResponse,
    TaskBoardPolicyPipelineResponse, TaskBoardPolicyPipelineSaveDraftRequest,
    TaskBoardPolicyPipelineSaveDraftResponse, TaskBoardPolicyPipelineSimulateRequest,
    TaskBoardPolicyPipelineSimulationResponse,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::default_board_root;
use crate::task_board::policy_graph::{
    self, PolicyCanvasRecord, PolicyCanvasWorkspace, PolicyGraph,
};

const POLICY_PIPELINE_CHANGE_CHANNEL: &str = "policy_pipeline";

/// Load the durable policy-canvas workspace from the database, seeding and
/// persisting a default workspace when the database is empty.
///
/// The review-text-paste dry-run canvas is repaired in place and re-persisted
/// when needed so the durable store always carries the current seed.
///
/// # Errors
/// Returns `CliError` when the database read or seed write fails.
#[expect(
    clippy::cognitive_complexity,
    reason = "sequential DB-empty recovery branches; splitting would obscure the intent"
)]
async fn load_or_seed_workspace(db: &AsyncDaemonDb) -> Result<PolicyCanvasWorkspace, CliError> {
    if let Some(mut workspace) = db.load_policy_workspace().await? {
        if workspace.ensure_review_text_paste_dry_run_canvas() {
            db.replace_policy_workspace(&workspace).await?;
            feed_gate_cache(&workspace);
        }
        return Ok(workspace);
    }
    // DB is empty. Before seeding random canvas IDs the connected app wouldn't
    // recognise, try recovering from the legacy JSON file. This handles the case
    // where the DB was wiped after startup (e.g. format change, hardware glitch)
    // while the JSON still describes the user's canvases.
    if let Some(mut workspace) = try_recover_canvas_json(db).await? {
        if workspace.ensure_review_text_paste_dry_run_canvas() {
            db.replace_policy_workspace(&workspace).await?;
        }
        feed_gate_cache(&workspace);
        return Ok(workspace);
    }
    let workspace = PolicyCanvasWorkspace::seeded();
    db.replace_policy_workspace(&workspace).await?;
    feed_gate_cache(&workspace);
    Ok(workspace)
}

const CANVAS_WORKSPACE_FILE: &str = "policy-canvases-v1.json";
const CANVAS_WORKSPACE_IMPORTED_SUFFIX: &str = ".imported.bak";

/// Attempt to import `policy-canvases-v1.json` into an empty database.
///
/// Returns the imported workspace on success, `None` when no importable file
/// exists or when parsing fails. Renames the source file to `*.imported.bak`
/// on success so the next call skips the import (same contract as the startup
/// import path in `policy_bootstrap.rs`).
async fn try_recover_canvas_json(
    db: &AsyncDaemonDb,
) -> Result<Option<PolicyCanvasWorkspace>, CliError> {
    let path = default_board_root().join(CANVAS_WORKSPACE_FILE);
    if !path.exists() {
        return Ok(None);
    }
    let Ok(contents) = fs::read_to_string(&path) else {
        return Ok(None);
    };
    let Ok(workspace) = serde_json::from_str::<PolicyCanvasWorkspace>(&contents) else {
        return Ok(None);
    };
    db.replace_policy_workspace(&workspace).await?;
    let mut bak_name: OsString = path.file_name().unwrap_or_default().to_os_string();
    bak_name.push(CANVAS_WORKSPACE_IMPORTED_SUFFIX);
    let bak = path.with_file_name(bak_name);
    let _ = fs::rename(&path, &bak);
    tracing::info!(
        target: "harness::daemon::policy",
        canvases = workspace.canvases.len(),
        "recovered policy canvas workspace from JSON into empty database"
    );
    Ok(Some(workspace))
}

/// Refresh the synchronous gating cache with the active enforced canvas
/// document so the allow/deny hot path never re-reads the database.
fn feed_gate_cache(workspace: &PolicyCanvasWorkspace) {
    policy_graph::store_gate_policy(
        &default_board_root(),
        workspace
            .active_enforced_canvas()
            .map(|canvas| canvas.document.clone()),
    );
}

fn feed_gate_cache_document(document: PolicyGraph) {
    policy_graph::store_gate_policy(&default_board_root(), Some(document));
}

/// Emit the `policy_pipeline` change event so websocket subscribers re-query.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing::warn! macro expands into a chain clippy reads as branchy"
)]
async fn bump_change_policy(db: &AsyncDaemonDb) {
    if let Err(error) = db.bump_change(POLICY_PIPELINE_CHANGE_CHANNEL).await {
        tracing::warn!(%error, "failed to bump policy_pipeline change marker");
    }
}

/// Load the V2 task-board policy canvas workspace snapshot.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be loaded.
pub(crate) async fn task_board_policy_canvas_workspace(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let workspace = load_or_seed_workspace(db).await?;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Create a new policy canvas and return the updated workspace snapshot.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub(crate) async fn create_task_board_policy_canvas(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyCanvasCreateRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let title = request.title.clone();
    let (workspace, _new_canvas) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_review_text_paste_dry_run_canvas();
            policy_graph::apply_create(workspace, title)
        })
        .await?;
    feed_gate_cache(&workspace);
    bump_change_policy(db).await;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Duplicate an existing policy canvas and return the updated workspace snapshot.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub(crate) async fn duplicate_task_board_policy_canvas(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyCanvasDuplicateRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let canvas_id = request.canvas_id.clone();
    let title = request.title.clone();
    let (workspace, _new_canvas) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_review_text_paste_dry_run_canvas();
            policy_graph::apply_duplicate(workspace, &canvas_id, title)
        })
        .await?;
    feed_gate_cache(&workspace);
    bump_change_policy(db).await;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Rename an existing policy canvas and return the updated workspace snapshot.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub(crate) async fn rename_task_board_policy_canvas(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyCanvasRenameRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let canvas_id = request.canvas_id.clone();
    let title = request.title.clone();
    let (workspace, ()) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_review_text_paste_dry_run_canvas();
            policy_graph::apply_rename(workspace, &canvas_id, title)
        })
        .await?;
    feed_gate_cache(&workspace);
    bump_change_policy(db).await;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Switch the authoritative active policy canvas and return the updated snapshot.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub(crate) async fn set_active_task_board_policy_canvas(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyCanvasSetActiveRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let canvas_id = request.canvas_id.clone();
    let (workspace, ()) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_review_text_paste_dry_run_canvas();
            policy_graph::apply_set_active(workspace, &canvas_id)
        })
        .await?;
    feed_gate_cache(&workspace);
    bump_change_policy(db).await;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Delete an existing policy canvas and return the updated workspace snapshot.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub(crate) async fn delete_task_board_policy_canvas(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyCanvasDeleteRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let canvas_id = request.canvas_id.clone();
    let (workspace, ()) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_review_text_paste_dry_run_canvas();
            policy_graph::apply_delete(workspace, &canvas_id)
        })
        .await?;
    feed_gate_cache(&workspace);
    bump_change_policy(db).await;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Toggle the policy enforcement kill switch for every policy canvas.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub(crate) async fn toggle_task_board_policy_canvas_enforcement(
    db: &AsyncDaemonDb,
    _request: &TaskBoardPolicyCanvasToggleEnforcementRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let (workspace, _disabled) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_review_text_paste_dry_run_canvas();
            Ok(policy_graph::apply_toggle_enforcement(workspace))
        })
        .await?;
    feed_gate_cache(&workspace);
    bump_change_policy(db).await;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Load the V2 task-board policy pipeline document for the active canvas.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be loaded.
pub(crate) async fn task_board_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyPipelineGetRequest,
) -> Result<TaskBoardPolicyPipelineResponse, CliError> {
    let workspace = load_or_seed_workspace(db).await?;
    policy_graph::read_active_document(&workspace, request.canvas_id.as_deref())
}

/// Save a V2 policy pipeline draft.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub(crate) async fn save_task_board_policy_pipeline_draft(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyPipelineSaveDraftRequest,
) -> Result<TaskBoardPolicyPipelineSaveDraftResponse, CliError> {
    let canvas_id = request.canvas_id.as_deref().ok_or_else(|| {
        CliErrorKind::invalid_transition(
            "policy canvas draft save requires canvas_id for row-scoped persistence".to_string(),
        )
    })?;
    let saved = db
        .save_policy_canvas_draft(canvas_id, request.document.clone(), request.if_revision)
        .await?;
    if saved.response.persisted {
        if saved.saved_active_canvas() {
            feed_gate_cache_document(saved.response.document.clone());
        }
        bump_change_policy(db).await;
    }
    Ok(saved.response)
}

/// Simulate a V2 policy pipeline in dry-run mode.
///
/// # Errors
/// Returns `CliError` when simulation state cannot be written.
pub(crate) async fn simulate_task_board_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyPipelineSimulateRequest,
) -> Result<TaskBoardPolicyPipelineSimulationResponse, CliError> {
    let document = request.document.clone();
    let expected_canvas_id = request.canvas_id.clone();
    let (workspace, result) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_review_text_paste_dry_run_canvas();
            policy_graph::apply_simulate(workspace, document, expected_canvas_id.as_deref())
        })
        .await?;
    feed_gate_cache(&workspace);
    bump_change_policy(db).await;
    Ok(result)
}

/// Promote a simulated V2 policy pipeline for enforcement.
///
/// # Errors
/// Returns `CliError` when simulation is missing/stale or promotion cannot be persisted.
pub(crate) async fn promote_task_board_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyPipelinePromoteRequest,
) -> Result<TaskBoardPolicyPipelinePromoteResponse, CliError> {
    let request = request.clone();
    let (workspace, response) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_review_text_paste_dry_run_canvas();
            policy_graph::apply_promote(workspace, &request)
        })
        .await?;
    feed_gate_cache(&workspace);
    bump_change_policy(db).await;
    Ok(response)
}

/// Summarize V2 policy pipeline audit state.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be loaded.
pub(crate) async fn audit_task_board_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyPipelineAuditRequest,
) -> Result<TaskBoardPolicyPipelineAuditResponse, CliError> {
    let workspace = load_or_seed_workspace(db).await?;
    policy_graph::audit_summary(&workspace, request.canvas_id.as_deref())
}

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
    use crate::errors::CliErrorKind;
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
            workspace.ensure_review_text_paste_dry_run_canvas();
            policy_graph::apply_import(workspace, document, title)
        })
        .await?;
    feed_gate_cache(&workspace);
    bump_change_policy(db).await;
    Ok(policy_canvas_workspace_response(&workspace))
}

fn policy_canvas_workspace_response(
    workspace: &PolicyCanvasWorkspace,
) -> TaskBoardPolicyCanvasWorkspaceResponse {
    TaskBoardPolicyCanvasWorkspaceResponse {
        schema_version: workspace.schema_version,
        active_canvas_id: workspace.active_canvas_id.clone(),
        policy_enforcement_kill_switch_active: workspace.enforcement_snapshot.is_some(),
        canvases: workspace
            .canvases
            .iter()
            .map(policy_canvas_summary)
            .collect(),
    }
}

fn policy_canvas_summary(canvas: &PolicyCanvasRecord) -> TaskBoardPolicyCanvasSummary {
    TaskBoardPolicyCanvasSummary {
        canvas_id: canvas.id.clone(),
        title: canvas.title.clone(),
        revision: canvas.document.revision,
        mode: canvas.document.mode,
        document: canvas.document.clone(),
        node_count: canvas.document.nodes.len(),
        edge_count: canvas.document.edges.len(),
        group_count: canvas.document.groups.len(),
        latest_simulation_trace_id: canvas
            .latest_simulation
            .as_ref()
            .map(|simulation| simulation.trace_id.clone()),
        latest_simulation_succeeded: canvas
            .latest_simulation
            .as_ref()
            .map(|simulation| simulation.succeeded),
        latest_simulation_at: canvas
            .latest_simulation
            .as_ref()
            .map(|simulation| simulation.simulated_at.clone()),
        updated_at: canvas.updated_at.clone(),
    }
}
