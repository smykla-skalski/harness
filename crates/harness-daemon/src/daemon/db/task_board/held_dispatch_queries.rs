//! Real implementations behind the matching
//! [`super::super::dispatch_admission_queries::DispatchAdmissionQueries`]
//! methods, called from the single consolidated trait impl in
//! `dispatch_admission_queries.rs` (a trait's methods can only be implemented
//! in one `impl` block per type, so the per-area files hand it plain
//! functions instead of each declaring their own `impl DispatchAdmissionQueries
//! for AsyncDaemonDb`). Split out of `held_dispatch.rs` to keep that file
//! under the repo's line budget; these functions stay part of the
//! `held_dispatch` module, not a separate area.

use sqlx::query_as;

use super::{
    ClaimedHeldTaskBoardDispatch, HeldClaimPreparation, HeldTaskBoardDispatch, commit_held_refusal,
    decode_applied, deliver_held_claim, held_conflict, prepare_held_claim_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::infra::io;
use crate::task_board::{TaskBoardHeldDispatchItem, TaskBoardHeldDispatchSummary};
use crate::daemon::db::prelude::*;

pub(in crate::daemon::db::task_board) async fn held_task_board_dispatch_summary(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardHeldDispatchSummary, CliError> {
    let rows = query_as::<_, (String, String, String, String)>(
        "SELECT intent_id, item_id, session_id, work_item_id
             FROM task_board_dispatch_intents WHERE status = 'held'
             ORDER BY created_at, intent_id",
    )
    .fetch_all(db.pool())
    .await
    .map_err(|error| db_error(format!("list held task board dispatches: {error}")))?;
    let items = rows
        .into_iter()
        .map(
            |(intent_id, board_item_id, session_id, work_item_id)| TaskBoardHeldDispatchItem {
                intent_id,
                board_item_id,
                session_id,
                work_item_id,
            },
        )
        .collect::<Vec<_>>();
    Ok(TaskBoardHeldDispatchSummary {
        count: items.len(),
        items,
    })
}

pub(in crate::daemon::db::task_board) async fn held_task_board_dispatch(
    db: &AsyncDaemonDb,
    board_item_id: &str,
) -> Result<HeldTaskBoardDispatch, CliError> {
    io::validate_safe_segment(board_item_id)?;
    let row = query_as::<_, (String, String)>(
        "SELECT intent_id, payload_json FROM task_board_dispatch_intents
             WHERE item_id = ?1 AND status = 'held'",
    )
    .bind(board_item_id)
    .fetch_optional(db.pool())
    .await
    .map_err(|error| db_error(format!("load held task board dispatch: {error}")))?
    .ok_or_else(|| held_conflict(board_item_id))?;
    Ok(HeldTaskBoardDispatch {
        intent_id: row.0,
        applied: decode_applied(&row.1)?,
    })
}

pub(in crate::daemon::db::task_board) async fn claim_held_task_board_dispatch(
    db: &AsyncDaemonDb,
    board_item_id: &str,
) -> Result<ClaimedHeldTaskBoardDispatch, CliError> {
    io::validate_safe_segment(board_item_id)?;
    let mut transaction = db
        .begin_immediate_transaction("task board held dispatch delivery")
        .await?;
    // Both arms must stay boxed. Awaited inline they fold their frames into
    // this future, which the websocket dispatcher, the HTTP task-board
    // operations and the route executor all await; that pushes those three
    // and this function past the 16384-byte threshold of
    // `clippy::large_futures`, which is denied here. `cargo check` will not
    // tell you, because the limit is a lint rather than a compile error.
    match Box::pin(prepare_held_claim_in_tx(&mut transaction, board_item_id)).await? {
        HeldClaimPreparation::Refused { context, message } => {
            Err(commit_held_refusal(transaction, context, message).await)
        }
        HeldClaimPreparation::Ready(prepared) => {
            Box::pin(deliver_held_claim(transaction, *prepared)).await
        }
    }
}
