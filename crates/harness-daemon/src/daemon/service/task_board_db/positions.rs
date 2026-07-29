use crate::daemon::db::{
    AsyncDaemonDb, CliError, TaskBoardLaneMutationResult, TaskBoardLanePositionInput,
    TaskBoardLaneResetInput, db_error,
};
use crate::daemon::protocol::{
    TaskBoardItemPositionMutationResponse, TaskBoardItemPositionSnapshot,
    TaskBoardResetItemPositionRequest, TaskBoardSetItemPositionRequest,
    TaskBoardShiftedItemRevision,
};
use crate::infra::io::validate_safe_segment;

pub(crate) async fn get_task_board_item_position_snapshot_db(
    db: &AsyncDaemonDb,
    item_id: &str,
) -> Result<TaskBoardItemPositionSnapshot, CliError> {
    validate_safe_segment(item_id)?;
    let snapshot = db.task_board_items_snapshot(None).await?;
    let item = snapshot
        .items
        .into_iter()
        .find(|entry| entry.item.id == item_id)
        .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
    Ok(TaskBoardItemPositionSnapshot {
        item: item.item,
        item_revision: item.item_revision,
        items_change_seq: snapshot.items_change_seq,
    })
}

pub(crate) async fn set_task_board_item_position_db(
    db: &AsyncDaemonDb,
    item_id: &str,
    request: &TaskBoardSetItemPositionRequest,
) -> Result<TaskBoardItemPositionMutationResponse, CliError> {
    validate_safe_segment(item_id)?;
    let result = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: item_id.to_owned(),
            status: Some(request.status),
            lane_position: request.lane_position,
            actor: request.actor.clone(),
            expected_item_revision: request.expected_item_revision,
            expected_items_change_seq: request.expected_items_change_seq,
        })
        .await?;
    Ok(position_mutation_response(result))
}

pub(crate) async fn reset_task_board_item_position_db(
    db: &AsyncDaemonDb,
    item_id: &str,
    request: &TaskBoardResetItemPositionRequest,
) -> Result<TaskBoardItemPositionMutationResponse, CliError> {
    validate_safe_segment(item_id)?;
    let result = db
        .reset_task_board_lane_position(TaskBoardLaneResetInput {
            item_id: item_id.to_owned(),
            actor: request.actor.clone(),
            expected_item_revision: request.expected_item_revision,
            expected_items_change_seq: request.expected_items_change_seq,
        })
        .await?;
    Ok(position_mutation_response(result))
}

fn position_mutation_response(
    result: TaskBoardLaneMutationResult,
) -> TaskBoardItemPositionMutationResponse {
    TaskBoardItemPositionMutationResponse {
        snapshot: TaskBoardItemPositionSnapshot {
            item: result.item,
            item_revision: result.item_revision,
            items_change_seq: result.items_change_seq,
        },
        shifted: result
            .shifted
            .into_iter()
            .map(|shift| TaskBoardShiftedItemRevision {
                item_id: shift.item_id,
                item_revision: shift.item_revision,
            })
            .collect(),
    }
}
