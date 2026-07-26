use sqlx::{Sqlite, Transaction};

use super::TaskBoardWorkflowTerminalProjection;
use super::dispatch::{PreparedDispatchSettlement, settle_prepared_dispatch_in_tx};
use super::projection::{
    apply_terminal_target, item_identity_matches, terminal_target, validate_terminal_execution,
};
use crate::daemon::db::task_board::ITEMS_CHANGE_SCOPE;
use crate::daemon::db::task_board::admission_lifecycle::{
    ensure_item_admission_can_terminate_in_tx, release_managed_worker_admission_in_tx,
};
use crate::daemon::db::task_board::items::{
    bump_change_in_tx, items_change_sequence_in_tx, load_item_in_tx,
};
use crate::daemon::db::task_board::lane_order::{
    LaneTransitionKind, record_lane_transition_audit_in_tx, replace_with_lane_transition_in_tx,
};
use crate::daemon::db::{CliError, db_error, utc_now};
use crate::task_board::{TaskBoardItem, TaskBoardWorkflowExecutionRecord};

pub(in crate::daemon::db::task_board) async fn project_terminal_execution_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<TaskBoardWorkflowTerminalProjection, CliError> {
    let owner = validate_terminal_execution(execution)?;
    let (item, item_revision) = load_item_in_tx(transaction, &execution.item_id)
        .await?
        .ok_or_else(|| db_error(format!("task-board item '{}' not found", execution.item_id)))?;
    let prepared = settle_prepared_dispatch_in_tx(transaction, execution).await?;
    // Both arms must stay boxed. Awaited inline they fold their own frames into
    // this future, which is awaited transitively from the cancel, status and
    // authority-settlement recorders; that pushes four of those awaits past the
    // 16384-byte threshold of `clippy::large_futures`, which is denied here.
    // `cargo check` will not tell you, because the limit is a lint rather than a
    // compile error.
    if item_identity_matches(&item, execution) {
        Box::pin(project_matched_terminal_item_in_tx(
            transaction,
            execution,
            &owner,
            (item, item_revision),
            &prepared,
        ))
        .await
    } else {
        Box::pin(project_foreign_terminal_item_in_tx(
            transaction,
            &owner,
            (item, item_revision),
            &prepared,
        ))
        .await
    }
}

/// The execution no longer owns the item it terminated against, so nothing is
/// written to the item at all -- the admission still has to be released.
async fn project_foreign_terminal_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    owner: &str,
    (item, item_revision): (TaskBoardItem, i64),
    prepared: &PreparedDispatchSettlement,
) -> Result<TaskBoardWorkflowTerminalProjection, CliError> {
    let committed_released = release_managed_worker_admission_in_tx(transaction, owner).await?;
    publish_settled_dispatch_change_in_tx(transaction, prepared, committed_released).await?;
    Ok(TaskBoardWorkflowTerminalProjection {
        item,
        item_revision,
        item_changed: false,
        admission_released: prepared.admission_released || committed_released,
    })
}

/// The execution still owns the item: apply the terminal target, release the
/// admission, and write the lane transition when the target actually moved the
/// item.
async fn project_matched_terminal_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    execution: &TaskBoardWorkflowExecutionRecord,
    owner: &str,
    (mut item, item_revision): (TaskBoardItem, i64),
    prepared: &PreparedDispatchSettlement,
) -> Result<TaskBoardWorkflowTerminalProjection, CliError> {
    let target = terminal_target(execution)?;
    let before = item.clone();
    let item_changed = apply_terminal_target(&mut item, &target);
    let committed_released = release_managed_worker_admission_in_tx(transaction, owner).await?;
    let admission_released = prepared.admission_released || committed_released;
    ensure_item_admission_can_terminate_in_tx(transaction, &execution.item_id).await?;
    let projected_revision = if item_changed {
        item.updated_at = utc_now();
        let (written, written_revision) = write_terminal_lane_transition_in_tx(
            transaction,
            before,
            (item, item_revision),
            committed_released,
        )
        .await?;
        item = written;
        written_revision
    } else {
        publish_settled_dispatch_change_in_tx(transaction, prepared, committed_released).await?;
        item_revision
    };
    Ok(TaskBoardWorkflowTerminalProjection {
        item,
        item_revision: projected_revision,
        item_changed,
        admission_released,
    })
}

async fn write_terminal_lane_transition_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    before: TaskBoardItem,
    (item, item_revision): (TaskBoardItem, i64),
    committed_released: bool,
) -> Result<(TaskBoardItem, i64), CliError> {
    let write = replace_with_lane_transition_in_tx(
        transaction,
        before,
        item_revision,
        item,
        LaneTransitionKind::Generic,
    )
    .await?;
    let sequence = terminal_change_sequence_in_tx(transaction, committed_released).await?;
    record_lane_transition_audit_in_tx(transaction, &write, sequence).await?;
    Ok((write.item, write.item_revision))
}

/// A committed admission release has already bumped the items scope, so the
/// lane-transition audit reads that sequence back instead of bumping a second
/// time.
async fn terminal_change_sequence_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    committed_released: bool,
) -> Result<i64, CliError> {
    if committed_released {
        items_change_sequence_in_tx(transaction).await
    } else {
        bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await
    }
}

/// Publish the dispatch settlement's own change when nothing else already did:
/// a committed admission release carries its own bump, and an item write
/// publishes through the lane transition instead.
async fn publish_settled_dispatch_change_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    prepared: &PreparedDispatchSettlement,
    committed_released: bool,
) -> Result<(), CliError> {
    if prepared.changed && !committed_released {
        bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
    }
    Ok(())
}
