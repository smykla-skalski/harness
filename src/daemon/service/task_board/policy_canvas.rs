use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    TaskBoardPolicyCanvasCreateRequest, TaskBoardPolicyCanvasDeleteRequest,
    TaskBoardPolicyCanvasDuplicateRequest, TaskBoardPolicyCanvasRenameRequest,
    TaskBoardPolicyCanvasSetActiveRequest, TaskBoardPolicyCanvasSetGlobalEnforcementRequest,
    TaskBoardPolicyCanvasSummary, TaskBoardPolicyCanvasWorkspaceResponse,
    TaskBoardPolicyExportRequest, TaskBoardPolicyExportResponse, TaskBoardPolicyImportRequest,
    TaskBoardPolicyImportResponse, TaskBoardPolicyPipelineAuditRequest,
    TaskBoardPolicyPipelineAuditResponse, TaskBoardPolicyPipelineGetRequest,
    TaskBoardPolicyPipelinePromoteRequest, TaskBoardPolicyPipelinePromoteResponse,
    TaskBoardPolicyPipelineResponse, TaskBoardPolicyPipelineSaveDraftRequest,
    TaskBoardPolicyPipelineSaveDraftResponse, TaskBoardPolicyPipelineSimulateRequest,
    TaskBoardPolicyPipelineSimulationResponse, TaskBoardPolicyScenarioCreateRequest,
    TaskBoardPolicyScenarioDeleteRequest, TaskBoardPolicyScenarioUpdateRequest,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::default_board_root;
use crate::task_board::policy_graph::{self, PolicyCanvasRecord, PolicyCanvasWorkspace};

const POLICY_PIPELINE_CHANGE_CHANNEL: &str = "policy_pipeline";

/// Load the durable policy-canvas workspace from the database, seeding and
/// persisting a default workspace when the database is empty.
///
/// Seeded automation canvases are repaired in place and re-persisted when
/// needed so the durable store always carries the current seed set.
///
/// # Errors
/// Returns `CliError` when the database read or seed write fails.
async fn load_or_seed_workspace(db: &AsyncDaemonDb) -> Result<PolicyCanvasWorkspace, CliError> {
    if let Some(mut workspace) = db.load_policy_workspace().await? {
        let repaired_canvases = workspace.ensure_seeded_automation_canvases();
        let seeded_scenarios = workspace.ensure_seeded_scenarios();
        if repaired_canvases || seeded_scenarios {
            db.replace_policy_workspace(&workspace).await?;
            feed_gate_cache(&workspace);
        }
        return Ok(workspace);
    }
    let workspace = PolicyCanvasWorkspace::seeded();
    db.replace_policy_workspace(&workspace).await?;
    feed_gate_cache(&workspace);
    Ok(workspace)
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
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
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
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
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
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
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
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
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
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
            policy_graph::apply_delete(workspace, &canvas_id)
        })
        .await?;
    feed_gate_cache(&workspace);
    bump_change_policy(db).await;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Set the global policy enforcement gate without mutating policy canvases.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub(crate) async fn set_task_board_policy_canvas_global_enforcement(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyCanvasSetGlobalEnforcementRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let enabled = request.enabled;
    let (workspace, _enabled) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
            Ok(policy_graph::apply_set_global_enforcement(
                workspace, enabled,
            ))
        })
        .await?;
    feed_gate_cache(&workspace);
    bump_change_policy(db).await;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Create a new editable policy scenario and return the updated workspace.
///
/// Scenarios feed only the confidence simulation, never the enforcement gate,
/// so this skips `feed_gate_cache`.
///
/// # Errors
/// Returns `CliError` when the scenario name is blank or persistence fails.
pub(crate) async fn create_task_board_policy_scenario(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyScenarioCreateRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let name = request.name.clone();
    let input = request.input.clone();
    let (workspace, _scenario) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
            policy_graph::apply_scenario_create(workspace, name, input)
        })
        .await?;
    bump_change_policy(db).await;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Update an existing policy scenario and return the updated workspace.
///
/// # Errors
/// Returns `CliError` when the name is blank, the id is unknown, or persistence
/// fails.
pub(crate) async fn update_task_board_policy_scenario(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyScenarioUpdateRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let id = request.id.clone();
    let name = request.name.clone();
    let input = request.input.clone();
    let (workspace, _scenario) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
            policy_graph::apply_scenario_update(workspace, &id, name, input)
        })
        .await?;
    bump_change_policy(db).await;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Delete a policy scenario and return the updated workspace.
///
/// # Errors
/// Returns `CliError` when the id is unknown or persistence fails.
pub(crate) async fn delete_task_board_policy_scenario(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyScenarioDeleteRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let id = request.id.clone();
    let (workspace, ()) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
            policy_graph::apply_scenario_delete(workspace, &id)
        })
        .await?;
    bump_change_policy(db).await;
    Ok(policy_canvas_workspace_response(&workspace))
}

/// Restore the default seeded scenario set and return the updated workspace.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be written.
pub(crate) async fn reset_task_board_policy_scenarios(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let (workspace, _scenarios) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_seeded_automation_canvases();
            Ok(policy_graph::apply_scenario_reset(workspace))
        })
        .await?;
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
            let document = saved
                .global_policy_enforcement_enabled
                .then(|| saved.response.document.clone());
            policy_graph::store_gate_policy(&default_board_root(), document);
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
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
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
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
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
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
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
        global_policy_enforcement_enabled: workspace.global_policy_enforcement_enabled,
        canvases: workspace
            .canvases
            .iter()
            .map(policy_canvas_summary)
            .collect(),
        scenarios: workspace.scenarios.clone(),
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
