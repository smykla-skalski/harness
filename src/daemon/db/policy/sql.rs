//! Shared `SELECT` statements for the normalized policy tables.
//!
//! Both the async (`store_async`, sqlx) and the synchronous (`store_sync`,
//! rusqlite) readers project these exact column orders, so the two storage
//! stacks cannot drift. Writes live with the async store; only reads are shared.

pub(super) const SELECT_WORKSPACE: &str = "SELECT active_canvas_id, workspace_schema_version, manual_ocr_paste_canvas_deleted, \
    review_text_paste_dry_run_canvas_deleted, review_screenshot_extraction_canvas_deleted, enforcement_snapshot_json, \
    global_policy_enforcement_enabled \
    FROM policy_workspace WHERE singleton = 1";
pub(super) const SELECT_CANVASES: &str = "SELECT canvas_id, position, title, is_manual_ocr_paste_canvas, \
    is_review_text_paste_dry_run_canvas, is_review_screenshot_extraction_canvas, graph_schema_version, revision, mode, \
    layout_zoom, layout_offset_x, layout_offset_y, policy_trace_ids_json, latest_simulation_json, created_at, updated_at \
    FROM policy_canvases ORDER BY position, canvas_id";
pub(super) const SELECT_CANVAS_BY_ID: &str = "SELECT canvas_id, position, title, \
    is_manual_ocr_paste_canvas, is_review_text_paste_dry_run_canvas, is_review_screenshot_extraction_canvas, \
    graph_schema_version, revision, mode, layout_zoom, layout_offset_x, layout_offset_y, \
    policy_trace_ids_json, latest_simulation_json, created_at, updated_at \
    FROM policy_canvases WHERE canvas_id = ?1";
pub(super) const SELECT_NODES: &str = "SELECT canvas_id, node_id, position, label, kind_tag, kind_config_json, \
    automation_json, input_ports_json, output_ports_json, group_id, layout_x, layout_y, layout_source \
    FROM policy_nodes ORDER BY canvas_id, position";
pub(super) const SELECT_NODES_BY_CANVAS: &str = "SELECT canvas_id, node_id, position, label, \
    kind_tag, kind_config_json, automation_json, input_ports_json, output_ports_json, group_id, \
    layout_x, layout_y, layout_source FROM policy_nodes WHERE canvas_id = ?1 ORDER BY position";
pub(super) const SELECT_EDGES: &str = "SELECT canvas_id, edge_id, position, from_node, from_port, to_node, \
    to_port, label, condition_tag, condition_config_json \
    FROM policy_edges ORDER BY canvas_id, position";
pub(super) const SELECT_EDGES_BY_CANVAS: &str = "SELECT canvas_id, edge_id, position, from_node, \
    from_port, to_node, to_port, label, condition_tag, condition_config_json \
    FROM policy_edges WHERE canvas_id = ?1 ORDER BY position";
pub(super) const SELECT_GROUPS: &str = "SELECT canvas_id, group_id, position, label, color, frame_x, frame_y, \
    frame_width, frame_height FROM policy_groups ORDER BY canvas_id, position";
pub(super) const SELECT_GROUPS_BY_CANVAS: &str = "SELECT canvas_id, group_id, position, label, \
    color, frame_x, frame_y, frame_width, frame_height FROM policy_groups WHERE canvas_id = ?1 \
    ORDER BY position";
pub(super) const SELECT_GROUP_NODES: &str = "SELECT canvas_id, group_id, node_id, position FROM policy_group_nodes \
    ORDER BY canvas_id, group_id, position";
pub(super) const SELECT_GROUP_NODES_BY_CANVAS: &str = "SELECT canvas_id, group_id, node_id, \
    position FROM policy_group_nodes WHERE canvas_id = ?1 ORDER BY group_id, position";
