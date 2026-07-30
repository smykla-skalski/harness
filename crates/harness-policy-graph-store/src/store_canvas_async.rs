//! Canvas-scoped async writes for normalized policy storage.

use std::time::Instant;

use sqlx::{Sqlite, Transaction, query, query_as};

use crate::mapper::{self, CanvasRowSet};
#[cfg(any(test, feature = "test-support"))]
use crate::rows::WorkspaceRow;
use crate::rows::{CanvasRow, EdgeRow, GroupNodeRow, GroupRow, NodeRow};
#[cfg(any(test, feature = "test-support"))]
use crate::sql::SELECT_WORKSPACE;
use crate::sql::{
    SELECT_CANVAS_BY_ID, SELECT_EDGES_BY_CANVAS, SELECT_GROUP_NODES_BY_CANVAS,
    SELECT_GROUPS_BY_CANVAS, SELECT_NODES_BY_CANVAS,
};
use crate::store_async::insert_canvas_rowset;
use crate::{PolicyGraphStore, db_error};
use harness_kernel::errors::CliError;
use harness_task_board::policy_graph::{
    PolicyCanvasRecord, PolicyGraph, PolicyPipelineSaveResponse, apply_save_canvas_draft,
};

pub struct PolicyCanvasDraftSaveResult {
    pub response: PolicyPipelineSaveResponse,
    #[cfg(any(test, feature = "test-support"))]
    pub saved_canvas: PolicyCanvasRecord,
    #[cfg(any(test, feature = "test-support"))]
    pub active_canvas_id: String,
    #[cfg(any(test, feature = "test-support"))]
    pub global_policy_enforcement_enabled: bool,
}

#[cfg(any(test, feature = "test-support"))]
impl PolicyCanvasDraftSaveResult {
    #[must_use]
    pub fn saved_active_canvas(&self) -> bool {
        self.saved_canvas.id == self.active_canvas_id
    }

    #[must_use]
    pub fn gate_document(&self) -> Option<PolicyGraph> {
        (self.global_policy_enforcement_enabled && self.saved_active_canvas())
            .then(|| self.saved_canvas.live_document().cloned())
            .flatten()
    }
}

/// Save one policy-canvas draft without rewriting unrelated canvas rows.
///
/// # Errors
/// Returns [`CliError`] on revision conflicts, unknown canvases, validation
/// serialization failures, or SQL failures.
#[expect(
    clippy::cognitive_complexity,
    reason = "transactional canvas save measures load and write timing in one path"
)]
pub async fn save_policy_canvas_draft<D: PolicyGraphStore>(
    db: &D,
    canvas_id: &str,
    document: PolicyGraph,
    if_revision: u64,
) -> Result<PolicyCanvasDraftSaveResult, CliError> {
    let total_started = Instant::now();
    let mut transaction = db
        .begin_immediate_transaction("policy canvas draft save")
        .await?;
    let load_started = Instant::now();
    #[cfg(any(test, feature = "test-support"))]
    let workspace_row = load_workspace_row(&mut transaction).await?;
    let (mut canvas, position) = load_canvas_rowset(&mut transaction, canvas_id).await?;
    let load_elapsed = load_started.elapsed();
    let response = apply_save_canvas_draft(&mut canvas, document, if_revision)?;
    let write_started = Instant::now();
    if response.persisted {
        replace_canvas_rows(&mut transaction, &canvas, position).await?;
    }
    let write_elapsed = write_started.elapsed();
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit policy canvas draft save: {error}")))?;
    tracing::debug!(
        canvas_id,
        persisted = response.persisted,
        load_ms = load_elapsed.as_millis(),
        write_ms = write_elapsed.as_millis(),
        total_ms = total_started.elapsed().as_millis(),
        "saved policy canvas draft"
    );
    Ok(PolicyCanvasDraftSaveResult {
        response,
        #[cfg(any(test, feature = "test-support"))]
        saved_canvas: canvas,
        #[cfg(any(test, feature = "test-support"))]
        active_canvas_id: workspace_row.active_canvas_id,
        #[cfg(any(test, feature = "test-support"))]
        global_policy_enforcement_enabled: workspace_row.global_policy_enforcement_enabled,
    })
}

#[cfg(any(test, feature = "test-support"))]
async fn load_workspace_row(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<WorkspaceRow, CliError> {
    query_as::<_, WorkspaceRow>(SELECT_WORKSPACE)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load policy workspace row: {error}")))?
        .ok_or_else(|| db_error("policy workspace is not seeded".to_string()))
}

async fn load_canvas_rowset(
    transaction: &mut Transaction<'_, Sqlite>,
    canvas_id: &str,
) -> Result<(PolicyCanvasRecord, i64), CliError> {
    let canvas = query_as::<_, CanvasRow>(SELECT_CANVAS_BY_ID)
        .bind(canvas_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load policy canvas '{canvas_id}': {error}")))?
        .ok_or_else(|| db_error(format!("unknown policy canvas '{canvas_id}'")))?;
    let position = canvas.position;
    let rowset = CanvasRowSet {
        canvas,
        nodes: fetch_canvas_nodes(transaction, canvas_id).await?,
        edges: fetch_canvas_edges(transaction, canvas_id).await?,
        groups: fetch_canvas_groups(transaction, canvas_id).await?,
        group_nodes: fetch_canvas_group_nodes(transaction, canvas_id).await?,
    };
    mapper::assemble_canvas(rowset).map(|canvas| (canvas, position))
}

async fn replace_canvas_rows(
    transaction: &mut Transaction<'_, Sqlite>,
    canvas: &PolicyCanvasRecord,
    position: i64,
) -> Result<(), CliError> {
    delete_canvas_rows(transaction, &canvas.id).await?;
    let set = mapper::disassemble_canvas(canvas, position)?;
    insert_canvas_rowset(transaction, &set).await
}

async fn delete_canvas_rows(
    transaction: &mut Transaction<'_, Sqlite>,
    canvas_id: &str,
) -> Result<(), CliError> {
    for statement in [
        "DELETE FROM policy_group_nodes WHERE canvas_id = ?1",
        "DELETE FROM policy_groups WHERE canvas_id = ?1",
        "DELETE FROM policy_edges WHERE canvas_id = ?1",
        "DELETE FROM policy_nodes WHERE canvas_id = ?1",
        "DELETE FROM policy_canvases WHERE canvas_id = ?1",
    ] {
        query(statement)
            .bind(canvas_id)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("delete policy canvas '{canvas_id}': {error}")))?;
    }
    Ok(())
}

async fn fetch_canvas_nodes(
    transaction: &mut Transaction<'_, Sqlite>,
    canvas_id: &str,
) -> Result<Vec<NodeRow>, CliError> {
    query_as::<_, NodeRow>(SELECT_NODES_BY_CANVAS)
        .bind(canvas_id)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load policy canvas nodes '{canvas_id}': {error}")))
}

async fn fetch_canvas_edges(
    transaction: &mut Transaction<'_, Sqlite>,
    canvas_id: &str,
) -> Result<Vec<EdgeRow>, CliError> {
    query_as::<_, EdgeRow>(SELECT_EDGES_BY_CANVAS)
        .bind(canvas_id)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load policy canvas edges '{canvas_id}': {error}")))
}

async fn fetch_canvas_groups(
    transaction: &mut Transaction<'_, Sqlite>,
    canvas_id: &str,
) -> Result<Vec<GroupRow>, CliError> {
    query_as::<_, GroupRow>(SELECT_GROUPS_BY_CANVAS)
        .bind(canvas_id)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load policy canvas groups '{canvas_id}': {error}")))
}

async fn fetch_canvas_group_nodes(
    transaction: &mut Transaction<'_, Sqlite>,
    canvas_id: &str,
) -> Result<Vec<GroupNodeRow>, CliError> {
    query_as::<_, GroupNodeRow>(SELECT_GROUP_NODES_BY_CANVAS)
        .bind(canvas_id)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| {
            db_error(format!(
                "load policy canvas group-node rows '{canvas_id}': {error}"
            ))
        })
}
