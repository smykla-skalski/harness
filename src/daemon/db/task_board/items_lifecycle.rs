use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use crate::daemon::db::policy::restore_consumed_approval_grant_in_tx_at;
use crate::daemon::db::{CliError, db_error, utc_now};
use crate::errors::CliErrorKind;
use crate::task_board::{TaskBoardItem, TaskBoardStatus, TaskBoardWorkflowStatus};

pub(super) async fn ensure_estimates_are_editable_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<(), CliError> {
    let started = query_scalar::<_, bool>(
        "SELECT EXISTS(
             SELECT 1 FROM task_board_dispatch_intents
             WHERE item_id = ?1
               AND status IN ('starting', 'completed')
         )",
    )
    .bind(item_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("check task board estimate freeze: {error}")))?;
    if started {
        return Err(CliErrorKind::invalid_transition(format!(
            "task-board estimates for item '{item_id}' are frozen after worker start"
        ))
        .into());
    }
    Ok(())
}

pub(super) async fn cancel_prestart_dispatch_for_terminal_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<(), CliError> {
    let claimed = query_scalar::<_, bool>(
        "SELECT EXISTS(
             SELECT 1 FROM task_board_dispatch_intents
             WHERE item_id = ?1 AND status IN ('preparing_claimed', 'starting')
         )",
    )
    .bind(item_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("check claimed task board dispatch: {error}")))?;
    if claimed {
        return Err(CliErrorKind::invalid_transition(format!(
            "task-board item '{item_id}' cannot become terminal while its dispatch is claimed"
        ))
        .into());
    }

    let grants = query_as::<_, (Option<String>,)>(
        "SELECT consumed_approval_grant_id
         FROM task_board_dispatch_intents
         WHERE item_id = ?1 AND status IN ('preparing', 'held', 'pending')",
    )
    .bind(item_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load cancellable task board dispatch: {error}")))?;
    let now = utc_now();
    for (grant_id,) in grants {
        if let Some(grant_id) = grant_id {
            restore_consumed_approval_grant_in_tx_at(transaction.as_mut(), &grant_id, &now).await?;
        }
    }
    query(
        "UPDATE task_board_dispatch_intents
         SET status = 'failed', claim_token = NULL, claimed_at = NULL,
             last_error = 'item became terminal before worker start',
             updated_at = ?2, completed_at = ?2
         WHERE item_id = ?1 AND status IN ('preparing', 'held', 'pending')",
    )
    .bind(item_id)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("cancel pre-start task board dispatch: {error}")))?;
    Ok(())
}

pub(super) fn task_board_item_is_terminal(item: &TaskBoardItem) -> bool {
    item.is_deleted()
        || matches!(item.status, TaskBoardStatus::Done | TaskBoardStatus::Failed)
        || matches!(
            item.workflow.status,
            TaskBoardWorkflowStatus::Completed
                | TaskBoardWorkflowStatus::Failed
                | TaskBoardWorkflowStatus::Cancelled
        )
}
