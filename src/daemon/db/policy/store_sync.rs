//! Synchronous (rusqlite) read of the normalized policy workspace.
//!
//! The daemon writes policy through the async (sqlx) `store_async` path. The
//! synchronous `harness` CLI gating cold-fill reads the active policy here,
//! without spinning up a tokio runtime. Both readers share the `SELECT_*` SQL in
//! [`super::sql`] and the row-to-domain conversion in [`super::mapper`], so the
//! two storage stacks cannot drift.

use std::collections::HashMap;

use super::super::{CliError, DaemonDb, OptionalExtension, db_error};
use super::mapper::{self, CanvasRowSet};
use super::rows::{CanvasRow, EdgeRow, GroupNodeRow, GroupRow, NodeRow, WorkspaceRow};
use super::sql::{
    SELECT_CANVASES, SELECT_EDGES, SELECT_GROUP_NODES, SELECT_GROUPS, SELECT_NODES,
    SELECT_WORKSPACE,
};
use crate::task_board::policy_graph::PolicyCanvasWorkspace;

impl DaemonDb {
    /// Load the durable policy canvas workspace, or `None` when unseeded.
    ///
    /// Synchronous mirror of the async `load_policy_workspace`: six bulk SELECTs
    /// grouped in memory and handed to the shared mapper. Reads run on the single
    /// rusqlite connection (WAL), so a concurrent async writer never blocks it.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or deserialization failures.
    pub(crate) fn load_policy_workspace(&self) -> Result<Option<PolicyCanvasWorkspace>, CliError> {
        let Some(workspace_row) = self.read_policy_workspace_row()? else {
            return Ok(None);
        };
        let canvases = self.read_policy_canvases()?;
        let mut nodes = group_by(self.read_policy_nodes()?, |row| row.canvas_id.clone());
        let mut edges = group_by(self.read_policy_edges()?, |row| row.canvas_id.clone());
        let mut groups = group_by(self.read_policy_groups()?, |row| row.canvas_id.clone());
        let mut group_nodes = group_by(self.read_policy_group_nodes()?, |row| row.canvas_id.clone());
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
        Ok(Some(mapper::assemble_workspace(workspace_row, records)))
    }

    fn read_policy_workspace_row(&self) -> Result<Option<WorkspaceRow>, CliError> {
        self.conn
            .query_row(SELECT_WORKSPACE, [], |row| {
                Ok(WorkspaceRow {
                    active_canvas_id: row.get(0)?,
                    workspace_schema_version: row.get(1)?,
                    review_text_paste_dry_run_canvas_deleted: row.get(2)?,
                })
            })
            .optional()
            .map_err(|error| db_error(format!("load policy workspace: {error}")))
    }

    fn read_policy_canvases(&self) -> Result<Vec<CanvasRow>, CliError> {
        let mut statement = self
            .conn
            .prepare(SELECT_CANVASES)
            .map_err(|error| db_error(format!("prepare policy canvases: {error}")))?;
        let rows = statement
            .query_map([], |row| {
                Ok(CanvasRow {
                    canvas_id: row.get(0)?,
                    position: row.get(1)?,
                    title: row.get(2)?,
                    is_review_text_paste_dry_run_canvas: row.get(3)?,
                    graph_schema_version: row.get(4)?,
                    revision: row.get(5)?,
                    mode: row.get(6)?,
                    policy_trace_ids_json: row.get(7)?,
                    latest_simulation_json: row.get(8)?,
                    created_at: row.get(9)?,
                    updated_at: row.get(10)?,
                })
            })
            .map_err(|error| db_error(format!("query policy canvases: {error}")))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| db_error(format!("read policy canvas row: {error}")))
    }

    fn read_policy_nodes(&self) -> Result<Vec<NodeRow>, CliError> {
        let mut statement = self
            .conn
            .prepare(SELECT_NODES)
            .map_err(|error| db_error(format!("prepare policy nodes: {error}")))?;
        let rows = statement
            .query_map([], |row| {
                Ok(NodeRow {
                    canvas_id: row.get(0)?,
                    node_id: row.get(1)?,
                    position: row.get(2)?,
                    label: row.get(3)?,
                    kind_tag: row.get(4)?,
                    kind_config_json: row.get(5)?,
                    automation_json: row.get(6)?,
                    input_ports_json: row.get(7)?,
                    output_ports_json: row.get(8)?,
                    group_id: row.get(9)?,
                    layout_x: row.get(10)?,
                    layout_y: row.get(11)?,
                })
            })
            .map_err(|error| db_error(format!("query policy nodes: {error}")))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| db_error(format!("read policy node row: {error}")))
    }

    fn read_policy_edges(&self) -> Result<Vec<EdgeRow>, CliError> {
        let mut statement = self
            .conn
            .prepare(SELECT_EDGES)
            .map_err(|error| db_error(format!("prepare policy edges: {error}")))?;
        let rows = statement
            .query_map([], |row| {
                Ok(EdgeRow {
                    canvas_id: row.get(0)?,
                    edge_id: row.get(1)?,
                    position: row.get(2)?,
                    from_node: row.get(3)?,
                    from_port: row.get(4)?,
                    to_node: row.get(5)?,
                    to_port: row.get(6)?,
                    label: row.get(7)?,
                    condition_tag: row.get(8)?,
                    condition_config_json: row.get(9)?,
                })
            })
            .map_err(|error| db_error(format!("query policy edges: {error}")))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| db_error(format!("read policy edge row: {error}")))
    }

    fn read_policy_groups(&self) -> Result<Vec<GroupRow>, CliError> {
        let mut statement = self
            .conn
            .prepare(SELECT_GROUPS)
            .map_err(|error| db_error(format!("prepare policy groups: {error}")))?;
        let rows = statement
            .query_map([], |row| {
                Ok(GroupRow {
                    canvas_id: row.get(0)?,
                    group_id: row.get(1)?,
                    position: row.get(2)?,
                    label: row.get(3)?,
                    color: row.get(4)?,
                    frame_x: row.get(5)?,
                    frame_y: row.get(6)?,
                    frame_width: row.get(7)?,
                    frame_height: row.get(8)?,
                })
            })
            .map_err(|error| db_error(format!("query policy groups: {error}")))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| db_error(format!("read policy group row: {error}")))
    }

    fn read_policy_group_nodes(&self) -> Result<Vec<GroupNodeRow>, CliError> {
        let mut statement = self
            .conn
            .prepare(SELECT_GROUP_NODES)
            .map_err(|error| db_error(format!("prepare policy group nodes: {error}")))?;
        let rows = statement
            .query_map([], |row| {
                Ok(GroupNodeRow {
                    canvas_id: row.get(0)?,
                    group_id: row.get(1)?,
                    node_id: row.get(2)?,
                    position: row.get(3)?,
                })
            })
            .map_err(|error| db_error(format!("query policy group nodes: {error}")))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| db_error(format!("read policy group node row: {error}")))
    }
}

fn group_by<T>(rows: Vec<T>, key: impl Fn(&T) -> String) -> HashMap<String, Vec<T>> {
    let mut map: HashMap<String, Vec<T>> = HashMap::new();
    for row in rows {
        map.entry(key(&row)).or_default().push(row);
    }
    map
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::db::AsyncDaemonDb;
    use tempfile::tempdir;

    #[test]
    fn sync_load_unseeded_returns_none() {
        let db = DaemonDb::open_in_memory().expect("open in-memory db");
        assert!(db.load_policy_workspace().expect("load").is_none());
    }

    #[tokio::test]
    async fn sync_reads_workspace_written_by_async() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("harness.db");
        let workspace = PolicyCanvasWorkspace::seeded();
        let async_db = AsyncDaemonDb::connect(&path).await.expect("connect async db");
        async_db
            .replace_policy_workspace(&workspace)
            .await
            .expect("write workspace via async stack");
        drop(async_db);
        let db = DaemonDb::open(&path).expect("open sync db on same file");
        let loaded = db
            .load_policy_workspace()
            .expect("sync load")
            .expect("workspace present");
        assert_eq!(loaded, workspace);
    }
}
