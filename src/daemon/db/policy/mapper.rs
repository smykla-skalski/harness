//! The single place normalized policy rows convert to and from the domain
//! `PolicyGraph` / `PolicyCanvasRecord` / `PolicyCanvasWorkspace`. Graph
//! structure maps to columns; the irreducible per-variant payloads (node kind,
//! edge condition, automation) round-trip as JSON.

use std::collections::HashMap;

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use super::super::db_error;
use super::rows::{CanvasRow, EdgeRow, GroupNodeRow, GroupRow, NodeRow, WorkspaceRow};
use crate::errors::CliError;
use crate::task_board::policy_graph::{
    PolicyCanvasPoint, PolicyCanvasRecord, PolicyCanvasRect, PolicyCanvasWorkspace, PolicyGraph,
    PolicyGraphEdge, PolicyGraphGroup, PolicyGraphLayout, PolicyGraphMode, PolicyGraphNode,
    PolicyGraphNodeLayout, PolicyGraphNodeLayoutSource,
};

/// All rows that make up a single persisted canvas.
pub(crate) struct CanvasRowSet {
    pub canvas: CanvasRow,
    pub nodes: Vec<NodeRow>,
    pub edges: Vec<EdgeRow>,
    pub groups: Vec<GroupRow>,
    pub group_nodes: Vec<GroupNodeRow>,
}

/// Split a canvas record into its row set. `position` is the canvas's order
/// within the workspace.
pub(crate) fn disassemble_canvas(
    record: &PolicyCanvasRecord,
    position: i64,
) -> Result<CanvasRowSet, CliError> {
    let document = &record.document;
    let canvas = CanvasRow {
        canvas_id: record.id.clone(),
        position,
        title: record.title.clone(),
        is_manual_ocr_paste_canvas: record.is_manual_ocr_paste_canvas,
        is_review_text_paste_dry_run_canvas: record.is_review_text_paste_dry_run_canvas,
        is_review_screenshot_extraction_canvas: record.is_review_screenshot_extraction_canvas,
        graph_schema_version: i64::from(document.schema_version),
        revision: i64::try_from(document.revision).unwrap_or(i64::MAX),
        mode: mode_to_str(document.mode).to_string(),
        layout_zoom: document.layout.zoom,
        layout_offset_x: i64::from(document.layout.offset.x),
        layout_offset_y: i64::from(document.layout.offset.y),
        policy_trace_ids_json: to_json(&document.policy_trace_ids)?,
        latest_simulation_json: record.latest_simulation.as_ref().map(to_json).transpose()?,
        created_at: record.created_at.clone(),
        updated_at: record.updated_at.clone(),
    };
    let layout = layout_index(&document.layout);
    let nodes = document
        .nodes
        .iter()
        .enumerate()
        .map(|(index, node)| node_row(&record.id, index, node, &layout))
        .collect::<Result<Vec<_>, _>>()?;
    let edges = document
        .edges
        .iter()
        .enumerate()
        .map(|(index, edge)| edge_row(&record.id, index, edge))
        .collect::<Result<Vec<_>, _>>()?;
    let groups = document
        .groups
        .iter()
        .enumerate()
        .map(|(index, group)| group_row(&record.id, index, group))
        .collect();
    let group_nodes = document
        .groups
        .iter()
        .flat_map(|group| {
            group
                .node_ids
                .iter()
                .enumerate()
                .map(|(index, node_id)| GroupNodeRow {
                    canvas_id: record.id.clone(),
                    group_id: group.id.as_str().to_owned(),
                    node_id: node_id.as_str().to_owned(),
                    position: idx(index),
                })
        })
        .collect();
    Ok(CanvasRowSet {
        canvas,
        nodes,
        edges,
        groups,
        group_nodes,
    })
}

/// Reassemble a canvas record from its row set. Child rows are expected ordered
/// by `position`; group membership and groups are re-sorted defensively.
pub(crate) fn assemble_canvas(set: CanvasRowSet) -> Result<PolicyCanvasRecord, CliError> {
    let CanvasRowSet {
        canvas,
        nodes,
        edges,
        groups,
        group_nodes,
    } = set;
    let document = PolicyGraph {
        schema_version: u16::try_from(canvas.graph_schema_version).unwrap_or_default(),
        revision: u64::try_from(canvas.revision).unwrap_or_default(),
        mode: mode_from_str(&canvas.mode),
        nodes: nodes
            .iter()
            .map(node_from_row)
            .collect::<Result<Vec<_>, _>>()?,
        edges: edges
            .iter()
            .map(edge_from_row)
            .collect::<Result<Vec<_>, _>>()?,
        groups: assemble_groups(groups, &group_nodes),
        layout: assemble_layout(&canvas, &nodes)?,
        policy_trace_ids: from_json(&canvas.policy_trace_ids_json, "policy_trace_ids")?,
    };
    Ok(PolicyCanvasRecord {
        id: canvas.canvas_id,
        title: canvas.title,
        created_at: canvas.created_at,
        updated_at: canvas.updated_at,
        document,
        latest_simulation: canvas
            .latest_simulation_json
            .as_deref()
            .map(|raw| from_json(raw, "latest_simulation"))
            .transpose()?,
        is_manual_ocr_paste_canvas: canvas.is_manual_ocr_paste_canvas,
        is_review_text_paste_dry_run_canvas: canvas.is_review_text_paste_dry_run_canvas,
        is_review_screenshot_extraction_canvas: canvas.is_review_screenshot_extraction_canvas,
    })
}

/// The `policy_workspace` singleton row for a workspace.
pub(crate) fn workspace_row(workspace: &PolicyCanvasWorkspace) -> Result<WorkspaceRow, CliError> {
    Ok(WorkspaceRow {
        active_canvas_id: workspace.active_canvas_id.clone(),
        workspace_schema_version: i64::from(workspace.schema_version),
        manual_ocr_paste_canvas_deleted: workspace.manual_ocr_paste_canvas_deleted,
        review_text_paste_dry_run_canvas_deleted: workspace
            .review_text_paste_dry_run_canvas_deleted,
        review_screenshot_extraction_canvas_deleted: workspace
            .review_screenshot_extraction_canvas_deleted,
        global_policy_enforcement_enabled: workspace.global_policy_enforcement_enabled,
    })
}

/// Combine the workspace singleton row with its assembled canvases.
pub(crate) fn assemble_workspace(
    row: WorkspaceRow,
    canvases: Vec<PolicyCanvasRecord>,
) -> Result<PolicyCanvasWorkspace, CliError> {
    Ok(PolicyCanvasWorkspace {
        schema_version: u32::try_from(row.workspace_schema_version).unwrap_or_default(),
        active_canvas_id: row.active_canvas_id,
        canvases,
        global_policy_enforcement_enabled: row.global_policy_enforcement_enabled,
        manual_ocr_paste_canvas_deleted: row.manual_ocr_paste_canvas_deleted,
        review_text_paste_dry_run_canvas_deleted: row.review_text_paste_dry_run_canvas_deleted,
        review_screenshot_extraction_canvas_deleted: row
            .review_screenshot_extraction_canvas_deleted,
    })
}

fn node_row(
    canvas_id: &str,
    position: usize,
    node: &PolicyGraphNode,
    layout: &HashMap<&str, &PolicyGraphNodeLayout>,
) -> Result<NodeRow, CliError> {
    let kind_value = to_value(&node.kind, "node kind")?;
    let kind_tag = tag_of(&kind_value, "kind");
    let (layout_x, layout_y, layout_source) = match layout.get(node.id.as_str()) {
        Some(layout) => (
            Some(i64::from(layout.x)),
            Some(i64::from(layout.y)),
            layout.source.map(layout_source_to_str).map(str::to_string),
        ),
        None => (None, None, None),
    };
    Ok(NodeRow {
        canvas_id: canvas_id.to_string(),
        node_id: node.id.as_str().to_owned(),
        position: idx(position),
        label: node.label.clone(),
        kind_tag,
        kind_config_json: stringify(&kind_value, "node kind")?,
        automation_json: node.automation.as_ref().map(to_json).transpose()?,
        input_ports_json: to_json(&node.input_ports)?,
        output_ports_json: to_json(&node.output_ports)?,
        group_id: node.group_id.as_ref().map(|id| id.as_str().to_owned()),
        layout_x,
        layout_y,
        layout_source,
    })
}

fn node_from_row(row: &NodeRow) -> Result<PolicyGraphNode, CliError> {
    Ok(PolicyGraphNode {
        id: row.node_id.clone().into(),
        label: row.label.clone(),
        kind: from_json(&row.kind_config_json, "node kind")?,
        automation: row
            .automation_json
            .as_deref()
            .map(|raw| from_json(raw, "node automation"))
            .transpose()?,
        input_ports: from_json(&row.input_ports_json, "node input ports")?,
        output_ports: from_json(&row.output_ports_json, "node output ports")?,
        group_id: row.group_id.clone().map(Into::into),
    })
}

fn edge_row(canvas_id: &str, position: usize, edge: &PolicyGraphEdge) -> Result<EdgeRow, CliError> {
    let condition_value = to_value(&edge.condition, "edge condition")?;
    Ok(EdgeRow {
        canvas_id: canvas_id.to_string(),
        edge_id: edge.id.as_str().to_owned(),
        position: idx(position),
        from_node: edge.from_node.as_str().to_owned(),
        from_port: edge.from_port.as_str().to_owned(),
        to_node: edge.to_node.as_str().to_owned(),
        to_port: edge.to_port.as_str().to_owned(),
        label: edge.label.clone(),
        condition_tag: tag_of(&condition_value, "condition"),
        condition_config_json: stringify(&condition_value, "edge condition")?,
    })
}

fn edge_from_row(row: &EdgeRow) -> Result<PolicyGraphEdge, CliError> {
    Ok(PolicyGraphEdge {
        id: row.edge_id.clone().into(),
        from_node: row.from_node.clone().into(),
        from_port: row.from_port.clone().into(),
        to_node: row.to_node.clone().into(),
        to_port: row.to_port.clone().into(),
        label: row.label.clone(),
        condition: from_json(&row.condition_config_json, "edge condition")?,
    })
}

fn group_row(canvas_id: &str, position: usize, group: &PolicyGraphGroup) -> GroupRow {
    GroupRow {
        canvas_id: canvas_id.to_string(),
        group_id: group.id.as_str().to_owned(),
        position: idx(position),
        label: group.label.clone(),
        color: group.color.clone(),
        frame_x: i64::from(group.frame.x),
        frame_y: i64::from(group.frame.y),
        frame_width: i64::from(group.frame.width),
        frame_height: i64::from(group.frame.height),
    }
}

fn assemble_groups(
    mut groups: Vec<GroupRow>,
    group_nodes: &[GroupNodeRow],
) -> Vec<PolicyGraphGroup> {
    groups.sort_by_key(|group| group.position);
    groups
        .into_iter()
        .map(|group| {
            let mut members: Vec<&GroupNodeRow> = group_nodes
                .iter()
                .filter(|member| member.group_id == group.group_id)
                .collect();
            members.sort_by_key(|member| member.position);
            PolicyGraphGroup {
                id: group.group_id.into(),
                label: group.label,
                color: group.color,
                frame: PolicyCanvasRect {
                    x: narrow(group.frame_x),
                    y: narrow(group.frame_y),
                    width: narrow(group.frame_width),
                    height: narrow(group.frame_height),
                },
                node_ids: members
                    .into_iter()
                    .map(|member| member.node_id.clone().into())
                    .collect(),
            }
        })
        .collect()
}

fn assemble_layout(canvas: &CanvasRow, nodes: &[NodeRow]) -> Result<PolicyGraphLayout, CliError> {
    let entries = nodes
        .iter()
        .filter_map(|row| match (row.layout_x, row.layout_y) {
            (Some(x), Some(y)) => Some(
                layout_source_from_str(&row.node_id, row.layout_source.as_deref()).map(|source| {
                    PolicyGraphNodeLayout {
                        node_id: row.node_id.clone().into(),
                        x: narrow(x),
                        y: narrow(y),
                        source,
                    }
                }),
            ),
            _ => None,
        })
        .collect::<Result<Vec<_>, CliError>>()?;
    Ok(PolicyGraphLayout {
        zoom: canvas.layout_zoom,
        offset: PolicyCanvasPoint {
            x: narrow(canvas.layout_offset_x),
            y: narrow(canvas.layout_offset_y),
        },
        nodes: entries,
    })
}

fn layout_index(layout: &PolicyGraphLayout) -> HashMap<&str, &PolicyGraphNodeLayout> {
    layout
        .nodes
        .iter()
        .map(|node| (node.node_id.as_str(), node))
        .collect()
}

fn layout_source_to_str(source: PolicyGraphNodeLayoutSource) -> &'static str {
    match source {
        PolicyGraphNodeLayoutSource::Auto => "auto",
        PolicyGraphNodeLayoutSource::Manual => "manual",
    }
}

fn layout_source_from_str(
    node_id: &str,
    raw: Option<&str>,
) -> Result<Option<PolicyGraphNodeLayoutSource>, CliError> {
    match raw {
        None => Ok(None),
        Some("auto") => Ok(Some(PolicyGraphNodeLayoutSource::Auto)),
        Some("manual") => Ok(Some(PolicyGraphNodeLayoutSource::Manual)),
        Some(other) => Err(db_error(format!(
            "invalid policy node layout source for {node_id}: {other}"
        ))),
    }
}

fn mode_to_str(mode: PolicyGraphMode) -> &'static str {
    match mode {
        PolicyGraphMode::Draft => "draft",
        PolicyGraphMode::DryRun => "dry_run",
        PolicyGraphMode::Enforced => "enforced",
    }
}

fn mode_from_str(raw: &str) -> PolicyGraphMode {
    match raw {
        "dry_run" => PolicyGraphMode::DryRun,
        "enforced" => PolicyGraphMode::Enforced,
        _ => PolicyGraphMode::Draft,
    }
}

fn tag_of(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn to_value<T: Serialize>(value: &T, context: &str) -> Result<Value, CliError> {
    serde_json::to_value(value).map_err(|error| db_error(format!("serialize {context}: {error}")))
}

fn stringify(value: &Value, context: &str) -> Result<String, CliError> {
    serde_json::to_string(value).map_err(|error| db_error(format!("serialize {context}: {error}")))
}

fn to_json<T: Serialize>(value: &T) -> Result<String, CliError> {
    serde_json::to_string(value)
        .map_err(|error| db_error(format!("serialize policy field: {error}")))
}

fn from_json<T: DeserializeOwned>(raw: &str, context: &str) -> Result<T, CliError> {
    serde_json::from_str(raw).map_err(|error| db_error(format!("parse {context}: {error}")))
}

fn idx(value: usize) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn narrow(value: i64) -> i32 {
    i32::try_from(value).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canvas_round_trips_through_rows() {
        let mut document = PolicyGraph::seeded_v2();
        document.layout.zoom = 1.25;
        document.layout.offset =
            crate::task_board::policy_graph::PolicyCanvasPoint { x: 320, y: 181 };
        if let Some(layout) = document.layout.nodes.first_mut() {
            layout.source = Some(PolicyGraphNodeLayoutSource::Manual);
        }
        let record = PolicyCanvasRecord::new("Default", document, None);
        let rows = disassemble_canvas(&record, 0).expect("disassemble canvas");
        let restored = assemble_canvas(rows).expect("assemble canvas");
        assert_eq!(restored, record);
    }

    #[test]
    fn workspace_round_trips_through_rows() {
        let workspace = PolicyCanvasWorkspace::seeded();
        let row = workspace_row(&workspace).expect("workspace row");
        let restored =
            assemble_workspace(row, workspace.canvases.clone()).expect("assemble workspace");
        assert_eq!(restored, workspace);
    }
}
