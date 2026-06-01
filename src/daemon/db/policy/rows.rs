//! Typed model layer for the normalized policy-graph tables (schema v15). One
//! `FromRow` struct per table; `super::mapper` is the single place these convert
//! to and from the domain `PolicyGraph` / `PolicyCanvasRecord`.

use sqlx::FromRow;

/// One row of `policy_workspace` (singleton).
#[derive(Debug, Clone, FromRow)]
pub(crate) struct WorkspaceRow {
    pub active_canvas_id: String,
    pub workspace_schema_version: i64,
    pub review_text_paste_dry_run_canvas_deleted: bool,
    pub enforcement_snapshot_json: Option<String>,
}

/// One row of `policy_canvases`. Document structure lives in the child tables;
/// the derived simulation cache rides as a JSON column.
#[derive(Debug, Clone, FromRow)]
pub(crate) struct CanvasRow {
    pub canvas_id: String,
    pub position: i64,
    pub title: String,
    pub is_review_text_paste_dry_run_canvas: bool,
    pub graph_schema_version: i64,
    pub revision: i64,
    pub mode: String,
    pub policy_trace_ids_json: String,
    pub latest_simulation_json: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

/// One row of `policy_nodes`. The variant payload (`kind`) and automation ride
/// as JSON; `kind_tag` is the queryable discriminator; layout merges in here.
#[derive(Debug, Clone, FromRow)]
pub(crate) struct NodeRow {
    pub canvas_id: String,
    pub node_id: String,
    pub position: i64,
    pub label: String,
    pub kind_tag: String,
    pub kind_config_json: String,
    pub automation_json: Option<String>,
    pub input_ports_json: String,
    pub output_ports_json: String,
    pub group_id: Option<String>,
    pub layout_x: Option<i64>,
    pub layout_y: Option<i64>,
}

/// One row of `policy_edges`. The edge condition rides as JSON with a queryable
/// `condition_tag` discriminator.
#[derive(Debug, Clone, FromRow)]
pub(crate) struct EdgeRow {
    pub canvas_id: String,
    pub edge_id: String,
    pub position: i64,
    pub from_node: String,
    pub from_port: String,
    pub to_node: String,
    pub to_port: String,
    pub label: Option<String>,
    pub condition_tag: String,
    pub condition_config_json: String,
}

/// One row of `policy_groups`.
#[derive(Debug, Clone, FromRow)]
pub(crate) struct GroupRow {
    pub canvas_id: String,
    pub group_id: String,
    pub position: i64,
    pub label: String,
    pub color: Option<String>,
    pub frame_x: i64,
    pub frame_y: i64,
    pub frame_width: i64,
    pub frame_height: i64,
}

/// One row of `policy_group_nodes` - a group's ordered membership.
#[derive(Debug, Clone, FromRow)]
pub(crate) struct GroupNodeRow {
    pub canvas_id: String,
    pub group_id: String,
    pub node_id: String,
    pub position: i64,
}
