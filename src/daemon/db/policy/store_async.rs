//! Async CRUD for the normalized policy tables on `AsyncDaemonDb`. Reads use
//! five bulk SELECTs grouped in memory; writes and read-modify-write run under a
//! single immediate transaction so concurrent canvas edits never lose updates.

use std::collections::HashMap;

use sqlx::{Sqlite, Transaction, query, query_as};

use super::super::{AsyncDaemonDb, CliError, db_error, utc_now};
use super::mapper::{self, CanvasRowSet};
use super::rows::{CanvasRow, EdgeRow, GroupNodeRow, GroupRow, NodeRow, WorkspaceRow};
use super::sql::{
    SELECT_CANVASES, SELECT_EDGES, SELECT_GROUP_NODES, SELECT_GROUPS, SELECT_NODES,
    SELECT_WORKSPACE,
};
use crate::task_board::policy_graph::PolicyCanvasWorkspace;

impl AsyncDaemonDb {
    /// Load the durable policy canvas workspace, or `None` when unseeded.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or deserialization failures.
    pub(crate) async fn load_policy_workspace(
        &self,
    ) -> Result<Option<PolicyCanvasWorkspace>, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("policy workspace load")
            .await?;
        let workspace = load_workspace_in_tx(&mut transaction).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit policy workspace load: {error}")))?;
        Ok(workspace)
    }

    /// Replace the entire durable policy workspace with `workspace`.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or serialization failures.
    pub(crate) async fn replace_policy_workspace(
        &self,
        workspace: &PolicyCanvasWorkspace,
    ) -> Result<(), CliError> {
        let mut transaction = self
            .begin_immediate_transaction("policy workspace replace")
            .await?;
        write_workspace_in_tx(&mut transaction, workspace).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit policy workspace replace: {error}")))?;
        Ok(())
    }

    /// Atomically read-modify-write the policy workspace. `mutate` sees the
    /// current workspace (seeded if absent) and may reject the change; on error
    /// the transaction rolls back and on-disk state is unchanged.
    ///
    /// # Errors
    /// Returns [`CliError`] from `mutate` or on SQL failures.
    pub(crate) async fn update_policy_workspace<F, R>(
        &self,
        mutate: F,
    ) -> Result<(PolicyCanvasWorkspace, R), CliError>
    where
        F: FnOnce(&mut PolicyCanvasWorkspace) -> Result<R, CliError>,
    {
        let mut transaction = self
            .begin_immediate_transaction("policy workspace update")
            .await?;
        let mut workspace = load_workspace_in_tx(&mut transaction)
            .await?
            .unwrap_or_else(PolicyCanvasWorkspace::seeded);
        let result = mutate(&mut workspace)?;
        write_workspace_in_tx(&mut transaction, &workspace).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit policy workspace update: {error}")))?;
        Ok((workspace, result))
    }
}

async fn load_workspace_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<Option<PolicyCanvasWorkspace>, CliError> {
    let Some(workspace_row) = query_as::<_, WorkspaceRow>(SELECT_WORKSPACE)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load policy workspace: {error}")))?
    else {
        return Ok(None);
    };
    let canvases = query_as::<_, CanvasRow>(SELECT_CANVASES)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load policy canvases: {error}")))?;
    let mut nodes = group_by(fetch_nodes(transaction).await?, |row| row.canvas_id.clone());
    let mut edges = group_by(fetch_edges(transaction).await?, |row| row.canvas_id.clone());
    let mut groups = group_by(fetch_groups(transaction).await?, |row| {
        row.canvas_id.clone()
    });
    let mut group_nodes = group_by(fetch_group_nodes(transaction).await?, |row| {
        row.canvas_id.clone()
    });
    let records = canvases
        .into_iter()
        .map(|canvas| {
            let canvas_id = canvas.canvas_id.clone();
            mapper::assemble_canvas(CanvasRowSet {
                nodes: nodes.remove(&canvas_id).unwrap_or_default(),
                edges: edges.remove(&canvas_id).unwrap_or_default(),
                groups: groups.remove(&canvas_id).unwrap_or_default(),
                group_nodes: group_nodes.remove(&canvas_id).unwrap_or_default(),
                canvas,
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    mapper::assemble_workspace(workspace_row, records).map(Some)
}

async fn fetch_nodes(transaction: &mut Transaction<'_, Sqlite>) -> Result<Vec<NodeRow>, CliError> {
    query_as::<_, NodeRow>(SELECT_NODES)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load policy nodes: {error}")))
}

async fn fetch_edges(transaction: &mut Transaction<'_, Sqlite>) -> Result<Vec<EdgeRow>, CliError> {
    query_as::<_, EdgeRow>(SELECT_EDGES)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load policy edges: {error}")))
}

async fn fetch_groups(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<Vec<GroupRow>, CliError> {
    query_as::<_, GroupRow>(SELECT_GROUPS)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load policy groups: {error}")))
}

async fn fetch_group_nodes(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<Vec<GroupNodeRow>, CliError> {
    query_as::<_, GroupNodeRow>(SELECT_GROUP_NODES)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load policy group nodes: {error}")))
}

async fn write_workspace_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace: &PolicyCanvasWorkspace,
) -> Result<(), CliError> {
    clear_policy_rows(transaction).await?;
    for (position, record) in workspace.canvases.iter().enumerate() {
        let set = mapper::disassemble_canvas(record, i64::try_from(position).unwrap_or(i64::MAX))?;
        insert_canvas_rowset(transaction, &set).await?;
    }
    let row = mapper::workspace_row(workspace)?;
    query(UPSERT_WORKSPACE)
        .bind(row.active_canvas_id)
        .bind(row.workspace_schema_version)
        .bind(row.manual_ocr_paste_canvas_deleted)
        .bind(row.review_text_paste_dry_run_canvas_deleted)
        .bind(row.review_screenshot_extraction_canvas_deleted)
        .bind(row.enforcement_snapshot_json)
        .bind(row.global_policy_enforcement_enabled)
        .bind(utc_now())
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("write policy workspace: {error}")))?;
    Ok(())
}

async fn clear_policy_rows(transaction: &mut Transaction<'_, Sqlite>) -> Result<(), CliError> {
    for statement in [
        "DELETE FROM policy_group_nodes",
        "DELETE FROM policy_groups",
        "DELETE FROM policy_edges",
        "DELETE FROM policy_nodes",
        "DELETE FROM policy_canvases",
    ] {
        query(statement)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("clear policy rows: {error}")))?;
    }
    Ok(())
}

pub(super) async fn insert_canvas_rowset(
    transaction: &mut Transaction<'_, Sqlite>,
    set: &CanvasRowSet,
) -> Result<(), CliError> {
    insert_canvas(transaction, &set.canvas).await?;
    insert_nodes(transaction, &set.nodes).await?;
    insert_edges(transaction, &set.edges).await?;
    insert_groups(transaction, &set.groups).await?;
    insert_group_nodes(transaction, &set.group_nodes).await
}

async fn insert_nodes(
    transaction: &mut Transaction<'_, Sqlite>,
    nodes: &[NodeRow],
) -> Result<(), CliError> {
    for node in nodes {
        insert_node(transaction, node).await?;
    }
    Ok(())
}

async fn insert_edges(
    transaction: &mut Transaction<'_, Sqlite>,
    edges: &[EdgeRow],
) -> Result<(), CliError> {
    for edge in edges {
        insert_edge(transaction, edge).await?;
    }
    Ok(())
}

async fn insert_groups(
    transaction: &mut Transaction<'_, Sqlite>,
    groups: &[GroupRow],
) -> Result<(), CliError> {
    for group in groups {
        insert_group(transaction, group).await?;
    }
    Ok(())
}

async fn insert_group_nodes(
    transaction: &mut Transaction<'_, Sqlite>,
    group_nodes: &[GroupNodeRow],
) -> Result<(), CliError> {
    for member in group_nodes {
        insert_group_node(transaction, member).await?;
    }
    Ok(())
}

async fn insert_canvas(
    transaction: &mut Transaction<'_, Sqlite>,
    row: &CanvasRow,
) -> Result<(), CliError> {
    query(INSERT_CANVAS)
        .bind(&row.canvas_id)
        .bind(row.position)
        .bind(&row.title)
        .bind(row.is_manual_ocr_paste_canvas)
        .bind(row.is_review_text_paste_dry_run_canvas)
        .bind(row.is_review_screenshot_extraction_canvas)
        .bind(row.graph_schema_version)
        .bind(row.revision)
        .bind(&row.mode)
        .bind(row.layout_zoom)
        .bind(row.layout_offset_x)
        .bind(row.layout_offset_y)
        .bind(&row.policy_trace_ids_json)
        .bind(&row.latest_simulation_json)
        .bind(&row.created_at)
        .bind(&row.updated_at)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("insert policy canvas: {error}")))?;
    Ok(())
}

async fn insert_node(
    transaction: &mut Transaction<'_, Sqlite>,
    row: &NodeRow,
) -> Result<(), CliError> {
    query(INSERT_NODE)
        .bind(&row.canvas_id)
        .bind(&row.node_id)
        .bind(row.position)
        .bind(&row.label)
        .bind(&row.kind_tag)
        .bind(&row.kind_config_json)
        .bind(&row.automation_json)
        .bind(&row.input_ports_json)
        .bind(&row.output_ports_json)
        .bind(&row.group_id)
        .bind(row.layout_x)
        .bind(row.layout_y)
        .bind(&row.layout_source)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("insert policy node: {error}")))?;
    Ok(())
}

async fn insert_edge(
    transaction: &mut Transaction<'_, Sqlite>,
    row: &EdgeRow,
) -> Result<(), CliError> {
    query(INSERT_EDGE)
        .bind(&row.canvas_id)
        .bind(&row.edge_id)
        .bind(row.position)
        .bind(&row.from_node)
        .bind(&row.from_port)
        .bind(&row.to_node)
        .bind(&row.to_port)
        .bind(&row.label)
        .bind(&row.condition_tag)
        .bind(&row.condition_config_json)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("insert policy edge: {error}")))?;
    Ok(())
}

async fn insert_group(
    transaction: &mut Transaction<'_, Sqlite>,
    row: &GroupRow,
) -> Result<(), CliError> {
    query(INSERT_GROUP)
        .bind(&row.canvas_id)
        .bind(&row.group_id)
        .bind(row.position)
        .bind(&row.label)
        .bind(&row.color)
        .bind(row.frame_x)
        .bind(row.frame_y)
        .bind(row.frame_width)
        .bind(row.frame_height)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("insert policy group: {error}")))?;
    Ok(())
}

async fn insert_group_node(
    transaction: &mut Transaction<'_, Sqlite>,
    row: &GroupNodeRow,
) -> Result<(), CliError> {
    query(INSERT_GROUP_NODE)
        .bind(&row.canvas_id)
        .bind(&row.group_id)
        .bind(&row.node_id)
        .bind(row.position)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("insert policy group node: {error}")))?;
    Ok(())
}

fn group_by<T>(rows: Vec<T>, key: impl Fn(&T) -> String) -> HashMap<String, Vec<T>> {
    let mut map: HashMap<String, Vec<T>> = HashMap::new();
    for row in rows {
        map.entry(key(&row)).or_default().push(row);
    }
    map
}

const UPSERT_WORKSPACE: &str = "INSERT INTO policy_workspace (singleton, active_canvas_id, workspace_schema_version, \
    manual_ocr_paste_canvas_deleted, review_text_paste_dry_run_canvas_deleted, review_screenshot_extraction_canvas_deleted, \
    enforcement_snapshot_json, global_policy_enforcement_enabled, updated_at) \
    VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) \
    ON CONFLICT(singleton) DO UPDATE SET \
    active_canvas_id = excluded.active_canvas_id, \
    workspace_schema_version = excluded.workspace_schema_version, \
    manual_ocr_paste_canvas_deleted = excluded.manual_ocr_paste_canvas_deleted, \
    review_text_paste_dry_run_canvas_deleted = excluded.review_text_paste_dry_run_canvas_deleted, \
    review_screenshot_extraction_canvas_deleted = excluded.review_screenshot_extraction_canvas_deleted, \
    enforcement_snapshot_json = excluded.enforcement_snapshot_json, \
    global_policy_enforcement_enabled = excluded.global_policy_enforcement_enabled, \
    updated_at = excluded.updated_at";
const INSERT_CANVAS: &str = "INSERT INTO policy_canvases (canvas_id, position, title, \
    is_manual_ocr_paste_canvas, is_review_text_paste_dry_run_canvas, is_review_screenshot_extraction_canvas, \
    graph_schema_version, revision, mode, layout_zoom, layout_offset_x, layout_offset_y, \
    policy_trace_ids_json, latest_simulation_json, created_at, updated_at) \
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)";
const INSERT_NODE: &str = "INSERT INTO policy_nodes (canvas_id, node_id, position, label, kind_tag, \
    kind_config_json, automation_json, input_ports_json, output_ports_json, group_id, layout_x, \
    layout_y, layout_source) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)";
const INSERT_EDGE: &str = "INSERT INTO policy_edges (canvas_id, edge_id, position, from_node, \
    from_port, to_node, to_port, label, condition_tag, condition_config_json) \
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)";
const INSERT_GROUP: &str = "INSERT INTO policy_groups (canvas_id, group_id, position, label, color, \
    frame_x, frame_y, frame_width, frame_height) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)";
const INSERT_GROUP_NODE: &str = "INSERT INTO policy_group_nodes (canvas_id, group_id, node_id, position) \
    VALUES (?1, ?2, ?3, ?4)";

#[cfg(test)]
#[path = "store_async_tests.rs"]
mod tests;
