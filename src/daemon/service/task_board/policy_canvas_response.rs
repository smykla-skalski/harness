use crate::daemon::protocol::{
    TaskBoardPolicyCanvasSummary, TaskBoardPolicyCanvasWorkspaceResponse,
};
use crate::task_board::policy_graph::{PolicyCanvasRecord, PolicyCanvasWorkspace};

pub(super) fn policy_canvas_workspace_response(
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
        live_document: canvas.live_document().cloned(),
        live_updated_at: canvas.live_updated_at().map(ToString::to_string),
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
