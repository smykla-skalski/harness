use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    TaskBoardPolicyCanvasCreateRequest, TaskBoardPolicyCanvasDeleteRequest,
    TaskBoardPolicyCanvasDuplicateRequest, TaskBoardPolicyCanvasRenameRequest,
    TaskBoardPolicyCanvasSetActiveRequest, TaskBoardPolicyCanvasSetGlobalEnforcementRequest,
    TaskBoardPolicyCanvasWorkspaceResponse, TaskBoardPolicyPipelineAuditRequest,
    TaskBoardPolicyPipelineAuditResponse, TaskBoardPolicyPipelineGetRequest,
    TaskBoardPolicyPipelineGoLiveDiffRequest, TaskBoardPolicyPipelineGoLiveDiffResponse,
    TaskBoardPolicyPipelineMakeLiveRequest, TaskBoardPolicyPipelineMakeLiveResponse,
    TaskBoardPolicyPipelinePromoteRequest, TaskBoardPolicyPipelinePromoteResponse,
    TaskBoardPolicyPipelineReplayRequest, TaskBoardPolicyPipelineReplayResponse,
    TaskBoardPolicyPipelineResponse, TaskBoardPolicyPipelineSaveDraftRequest,
    TaskBoardPolicyPipelineSaveDraftResponse, TaskBoardPolicyPipelineSimulateRequest,
    TaskBoardPolicyPipelineSimulationResponse, TaskBoardPolicyScenarioCreateRequest,
    TaskBoardPolicyScenarioDeleteRequest, TaskBoardPolicyScenarioUpdateRequest,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::default_board_root;
use crate::task_board::policy_graph::{self, PolicyCanvasWorkspace};

use super::policy_canvas_response::policy_canvas_workspace_response;

const POLICY_PIPELINE_CHANGE_CHANNEL: &str = "policy_pipeline";

/// Default and ceiling for how many recorded decisions a replay re-simulates.
const DEFAULT_REPLAY_LIMIT: u32 = 50;
const MAX_REPLAY_LIMIT: u32 = 500;

/// Load the durable policy-canvas workspace from the database, seeding and
/// persisting a default workspace when the database is empty.
///
/// Seeded automation canvases are repaired in place and re-persisted when
/// needed so the durable store always carries the current seed set.
///
/// # Errors
/// Returns `CliError` when the database read or seed write fails.
pub(super) async fn load_or_seed_workspace(
    db: &AsyncDaemonDb,
) -> Result<PolicyCanvasWorkspace, CliError> {
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
pub(super) fn feed_gate_cache(workspace: &PolicyCanvasWorkspace) {
    policy_graph::store_gate_policy_entry(
        &default_board_root(),
        workspace.active_live_canvas().map(|(canvas, document)| {
            policy_graph::CachedGatePolicy::for_canvas(canvas.id.clone(), document.clone())
        }),
    );
}

/// Emit the `policy_pipeline` change event so websocket subscribers re-query.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing::warn! macro expands into a chain clippy reads as branchy"
)]
pub(super) async fn bump_change_policy(db: &AsyncDaemonDb) {
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
    let input = request.input.clone();
    let (workspace, _scenario) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
            policy_graph::apply_scenario_create(workspace, &request.name, input)
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
    let input = request.input.clone();
    let (workspace, _scenario) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
            policy_graph::apply_scenario_update(workspace, &id, &request.name, input)
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
            let entry = saved
                .gate_document()
                .map(|document| policy_graph::CachedGatePolicy::for_canvas(canvas_id, document));
            policy_graph::store_gate_policy_entry(&default_board_root(), entry);
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

/// Make the active V2 policy pipeline live: refresh its simulation, promote it
/// to enforced mode, and enable global enforcement in one transaction.
///
/// # Errors
/// Returns `CliError` when the revision precondition fails, the document is not
/// valid to promote, or the workspace cannot be persisted.
pub(crate) async fn make_live_task_board_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyPipelineMakeLiveRequest,
) -> Result<TaskBoardPolicyPipelineMakeLiveResponse, CliError> {
    let request = request.clone();
    let (workspace, response) = db
        .update_policy_workspace(|workspace| {
            workspace.ensure_seeded_automation_canvases();
            workspace.ensure_seeded_scenarios();
            policy_graph::apply_make_live(workspace, &request)
        })
        .await?;
    feed_gate_cache(&workspace);
    bump_change_policy(db).await;
    Ok(TaskBoardPolicyPipelineMakeLiveResponse {
        document: response.document,
        trace_id: response.trace_id,
        global_policy_enforcement_enabled: response.global_policy_enforcement_enabled,
        workspace: policy_canvas_workspace_response(&workspace),
    })
}

/// Diff a candidate draft against the live enforced policy across every
/// scenario without mutating any durable state.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be loaded or the active
/// canvas cannot be resolved.
pub(crate) async fn go_live_diff_task_board_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyPipelineGoLiveDiffRequest,
) -> Result<TaskBoardPolicyPipelineGoLiveDiffResponse, CliError> {
    let workspace = load_or_seed_workspace(db).await?;
    policy_graph::apply_diff_against_live(
        &workspace,
        request.document.clone(),
        request.canvas_id.as_deref(),
    )
}

/// Replay the active draft against the recorded real-decision feed.
///
/// Read-only: loads the workspace and the most recent decisions recorded for
/// the canvas under review, then re-simulates the draft against each without
/// mutating any durable state.
///
/// # Errors
/// Returns `CliError` when durable policy state cannot be loaded, the recorded
/// feed cannot be read, or the active canvas cannot be resolved.
pub(crate) async fn replay_task_board_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyPipelineReplayRequest,
) -> Result<TaskBoardPolicyPipelineReplayResponse, CliError> {
    let workspace = load_or_seed_workspace(db).await?;
    let limit = request
        .limit
        .unwrap_or(DEFAULT_REPLAY_LIMIT)
        .clamp(1, MAX_REPLAY_LIMIT) as usize;
    let target_canvas_id = request
        .canvas_id
        .as_deref()
        .unwrap_or(workspace.active_canvas_id.as_str());
    let recorded = db
        .recent_policy_decisions_for_canvas(target_canvas_id, limit)
        .await?;
    policy_graph::replay::apply_replay(&workspace, &recorded, request.canvas_id.as_deref())
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
