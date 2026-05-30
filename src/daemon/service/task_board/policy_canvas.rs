use crate::daemon::protocol::{
    TaskBoardPolicyCanvasCreateRequest, TaskBoardPolicyCanvasDeleteRequest,
    TaskBoardPolicyCanvasDuplicateRequest, TaskBoardPolicyCanvasRenameRequest,
    TaskBoardPolicyCanvasSetActiveRequest, TaskBoardPolicyCanvasSummary,
    TaskBoardPolicyCanvasWorkspaceResponse, TaskBoardPolicyPipelineAuditRequest,
    TaskBoardPolicyPipelineAuditResponse, TaskBoardPolicyPipelineGetRequest,
    TaskBoardPolicyPipelinePromoteRequest, TaskBoardPolicyPipelinePromoteResponse,
    TaskBoardPolicyPipelineResponse, TaskBoardPolicyPipelineSaveDraftRequest,
    TaskBoardPolicyPipelineSaveDraftResponse, TaskBoardPolicyPipelineSimulateRequest,
    TaskBoardPolicyPipelineSimulationResponse,
};
use crate::errors::CliError;
use crate::task_board::policy_graph::{PolicyCanvasRecord, PolicyCanvasWorkspace};
use crate::task_board::{PolicyPipelineStore, default_board_root};

/// Load the V2 task-board policy pipeline, seeding the default graph when absent.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be loaded.
pub fn task_board_policy_canvas_workspace()
-> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let workspace = policy_store().load_workspace_or_seed()?;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Create a new policy canvas and return the updated workspace snapshot.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub fn create_task_board_policy_canvas(
    request: &TaskBoardPolicyCanvasCreateRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let store = policy_store();
    let _ = store.create_canvas(request.title.clone())?;
    let workspace = store.load_workspace_or_seed()?;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Duplicate an existing policy canvas and return the updated workspace snapshot.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub fn duplicate_task_board_policy_canvas(
    request: &TaskBoardPolicyCanvasDuplicateRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let store = policy_store();
    let _ = store.duplicate_canvas(&request.canvas_id, request.title.clone())?;
    let workspace = store.load_workspace_or_seed()?;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Rename an existing policy canvas and return the updated workspace snapshot.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub fn rename_task_board_policy_canvas(
    request: &TaskBoardPolicyCanvasRenameRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let workspace = policy_store().rename_canvas(&request.canvas_id, request.title.clone())?;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Switch the authoritative active policy canvas and return the updated workspace snapshot.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub fn set_active_task_board_policy_canvas(
    request: &TaskBoardPolicyCanvasSetActiveRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let workspace = policy_store().set_active_canvas(&request.canvas_id)?;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Delete an existing policy canvas and return the updated workspace snapshot.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub fn delete_task_board_policy_canvas(
    request: &TaskBoardPolicyCanvasDeleteRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let workspace = policy_store().delete_canvas(&request.canvas_id)?;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Load the V2 task-board policy pipeline, seeding the default graph when absent.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be loaded.
pub fn task_board_policy_pipeline(
    request: &TaskBoardPolicyPipelineGetRequest,
) -> Result<TaskBoardPolicyPipelineResponse, CliError> {
    policy_store().load_or_seed_for_active_canvas(request.canvas_id.as_deref())
}

/// Save a V2 policy pipeline draft.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub fn save_task_board_policy_pipeline_draft(
    request: &TaskBoardPolicyPipelineSaveDraftRequest,
) -> Result<TaskBoardPolicyPipelineSaveDraftResponse, CliError> {
    policy_store().save_draft_for_active_canvas(
        request.document.clone(),
        request.if_revision,
        request.canvas_id.as_deref(),
    )
}

/// Simulate a V2 policy pipeline in dry-run mode.
///
/// # Errors
/// Returns `CliError` when simulation state cannot be written.
pub fn simulate_task_board_policy_pipeline(
    request: &TaskBoardPolicyPipelineSimulateRequest,
) -> Result<TaskBoardPolicyPipelineSimulationResponse, CliError> {
    policy_store()
        .simulate_for_active_canvas(request.document.clone(), request.canvas_id.as_deref())
}

/// Promote a simulated V2 policy pipeline for enforcement.
///
/// # Errors
/// Returns `CliError` when simulation is missing/stale or promotion cannot be persisted.
pub fn promote_task_board_policy_pipeline(
    request: &TaskBoardPolicyPipelinePromoteRequest,
) -> Result<TaskBoardPolicyPipelinePromoteResponse, CliError> {
    policy_store().promote(request)
}

/// Summarize V2 policy pipeline audit state.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be loaded.
pub fn audit_task_board_policy_pipeline(
    request: &TaskBoardPolicyPipelineAuditRequest,
) -> Result<TaskBoardPolicyPipelineAuditResponse, CliError> {
    policy_store().audit_summary_for_active_canvas(request.canvas_id.as_deref())
}

fn policy_canvas_workspace_response(
    workspace: &PolicyCanvasWorkspace,
) -> TaskBoardPolicyCanvasWorkspaceResponse {
    TaskBoardPolicyCanvasWorkspaceResponse {
        schema_version: workspace.schema_version,
        active_canvas_id: workspace.active_canvas_id.clone(),
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

fn policy_store() -> PolicyPipelineStore {
    PolicyPipelineStore::new(default_board_root())
}
