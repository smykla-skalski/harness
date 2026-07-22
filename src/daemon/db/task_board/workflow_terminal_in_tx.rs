use sqlx::{Sqlite, Transaction};

use super::TaskBoardWorkflowTerminalProjection;
use super::dispatch::settle_prepared_dispatch_in_tx;
use super::projection::{
    apply_terminal_target, item_identity_matches, terminal_target, validate_terminal_execution,
};
use crate::daemon::db::task_board::ITEMS_CHANGE_SCOPE;
use crate::daemon::db::task_board::admission_lifecycle::{
    ensure_item_admission_can_terminate_in_tx, release_managed_worker_admission_in_tx,
};
use crate::daemon::db::task_board::lane_order::{
    LaneTransitionKind, record_lane_transition_audit_in_tx, replace_with_lane_transition_in_tx,
};
use crate::daemon::db::task_board::items::{
    bump_change_in_tx, items_change_sequence_in_tx, load_item_in_tx,
};
use crate::daemon::db::{CliError, db_error, utc_now};
use crate::task_board::TaskBoardWorkflowExecutionRecord;

pub(in crate::daemon::db::task_board) async fn project_terminal_execution_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<TaskBoardWorkflowTerminalProjection, CliError> {
    let owner = validate_terminal_execution(execution)?;
    let (mut item, item_revision) = load_item_in_tx(transaction, &execution.item_id)
        .await?
        .ok_or_else(|| db_error(format!("task-board item '{}' not found", execution.item_id)))?;
    let prepared = settle_prepared_dispatch_in_tx(transaction, execution).await?;
    if !item_identity_matches(&item, execution) {
        let committed_released =
            release_managed_worker_admission_in_tx(transaction, &owner).await?;
        if prepared.changed && !committed_released {
            bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
        }
        return Ok(TaskBoardWorkflowTerminalProjection {
            item,
            item_revision,
            item_changed: false,
            admission_released: prepared.admission_released || committed_released,
        });
    }
    let target = terminal_target(execution)?;
    let before = item.clone();
    let item_changed = apply_terminal_target(&mut item, &target);
    let committed_released = release_managed_worker_admission_in_tx(transaction, &owner).await?;
    let admission_released = prepared.admission_released || committed_released;
    ensure_item_admission_can_terminate_in_tx(transaction, &execution.item_id).await?;
    let projected_revision = if item_changed {
        item.updated_at = utc_now();
        let write = replace_with_lane_transition_in_tx(
            transaction,
            before,
            item_revision,
            item,
            LaneTransitionKind::Generic,
        )
        .await?;
        let sequence = if committed_released {
            items_change_sequence_in_tx(transaction).await?
        } else {
            bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?
        };
        record_lane_transition_audit_in_tx(transaction, &write, sequence).await?;
        let updated_revision = write.item_revision;
        item = write.item;
        updated_revision
    } else {
        if prepared.changed && !committed_released {
            bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
        }
        item_revision
    };
    Ok(TaskBoardWorkflowTerminalProjection {
        item,
        item_revision: projected_revision,
        item_changed,
        admission_released,
    })
}
