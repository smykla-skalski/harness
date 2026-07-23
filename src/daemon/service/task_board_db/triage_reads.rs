use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardTriageOverrideClearInput, TaskBoardTriageOverrideMutationResult,
    TaskBoardTriageOverrideSetInput,
};
use crate::daemon::protocol::{
    TaskBoardClearTriageOverrideRequest, TaskBoardItemPositionSnapshot,
    TaskBoardSetTriageOverrideRequest, TaskBoardShiftedItemRevision,
    TaskBoardTriageCurrentResponse, TaskBoardTriageHistoryResponse,
    TaskBoardTriageOverrideMutationResponse,
};
use crate::errors::CliError;
use crate::infra::io::validate_safe_segment;

pub(crate) async fn get_task_board_item_triage_current_db(
    db: &AsyncDaemonDb,
    item_id: &str,
) -> Result<TaskBoardTriageCurrentResponse, CliError> {
    validate_safe_segment(item_id)?;
    let read = db.task_board_triage_current(item_id).await?;
    Ok(TaskBoardTriageCurrentResponse {
        current: read.current,
        triage_override: read.triage_override,
        effective: read.effective,
    })
}

pub(crate) async fn set_task_board_triage_override_db(
    db: &AsyncDaemonDb,
    item_id: &str,
    request: &TaskBoardSetTriageOverrideRequest,
) -> Result<TaskBoardTriageOverrideMutationResponse, CliError> {
    validate_safe_segment(item_id)?;
    let result = db
        .set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
            item_id: item_id.to_owned(),
            verdict: request.verdict,
            actor: request.actor.clone(),
            reason: request.reason.clone(),
            expected_item_revision: request.expected_item_revision,
            expected_items_change_seq: request.expected_items_change_seq,
        })
        .await?;
    Ok(triage_override_mutation_response(result))
}

pub(crate) async fn clear_task_board_triage_override_db(
    db: &AsyncDaemonDb,
    item_id: &str,
    request: &TaskBoardClearTriageOverrideRequest,
) -> Result<TaskBoardTriageOverrideMutationResponse, CliError> {
    validate_safe_segment(item_id)?;
    let result = db
        .clear_task_board_triage_override(TaskBoardTriageOverrideClearInput {
            item_id: item_id.to_owned(),
            actor: request.actor.clone(),
            expected_item_revision: request.expected_item_revision,
            expected_items_change_seq: request.expected_items_change_seq,
        })
        .await?;
    Ok(triage_override_mutation_response(result))
}

fn triage_override_mutation_response(
    result: TaskBoardTriageOverrideMutationResult,
) -> TaskBoardTriageOverrideMutationResponse {
    TaskBoardTriageOverrideMutationResponse {
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
        triage_override: result.override_,
        effective: result.effective,
    }
}

pub(crate) async fn get_task_board_item_triage_history_db(
    db: &AsyncDaemonDb,
    item_id: &str,
    before_generation: Option<u64>,
    limit: u32,
) -> Result<TaskBoardTriageHistoryResponse, CliError> {
    validate_safe_segment(item_id)?;
    let page = db
        .task_board_triage_history(item_id, before_generation, limit)
        .await?;
    Ok(TaskBoardTriageHistoryResponse {
        decisions: page.decisions,
        next_before_generation: page.next_before_generation,
    })
}
