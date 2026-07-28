use sqlx::{Sqlite, Transaction, query, query_scalar};

use super::super::admission_lifecycle::release_dispatch_admission_in_tx;
use super::super::workflow_dispatch::workflow_owner;
use super::super::workflow_dispatch_settlement::workflow_start_is_durable_in_tx;
use super::super::workflow_start_admission::commit_frozen_start_admission_in_tx;
use crate::daemon::db::{CliError, db_error, utc_now};
use crate::task_board::TaskBoardWorkflowExecutionRecord;

#[derive(Debug, Clone, Copy, Default)]
pub(in crate::daemon::db::task_board) struct PreparedDispatchSettlement {
    pub(in crate::daemon::db::task_board) changed: bool,
    pub(super) admission_released: bool,
}

pub(in crate::daemon::db::task_board) async fn settle_prepared_dispatch_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<PreparedDispatchSettlement, CliError> {
    let intent_id = query_scalar::<_, String>(
        "SELECT intent_id FROM task_board_dispatch_intents
         WHERE workflow_execution_id = ?1 AND item_id = ?2
           AND status = 'workflow_prepared'",
    )
    .bind(&execution.execution_id)
    .bind(&execution.item_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load terminal prepared dispatch: {error}")))?;
    let Some(intent_id) = intent_id else {
        return Ok(PreparedDispatchSettlement::default());
    };
    let started = workflow_start_is_durable_in_tx(transaction, execution).await?;
    if started {
        commit_frozen_start_admission_in_tx(
            transaction,
            &intent_id,
            &workflow_owner(&execution.execution_id),
        )
        .await?;
    } else {
        release_dispatch_admission_in_tx(transaction, &intent_id).await?;
    }
    mark_prepared_dispatch_settled_in_tx(transaction, &intent_id, execution, started).await?;
    let directly_released =
        started && admission_released_directly_in_tx(transaction, &intent_id, execution).await?;
    Ok(PreparedDispatchSettlement {
        changed: true,
        admission_released: !started || directly_released,
    })
}

/// Marks the prepared intent completed or failed, requiring the CAS on
/// `workflow_prepared` to have applied.
async fn mark_prepared_dispatch_settled_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    execution: &TaskBoardWorkflowExecutionRecord,
    started: bool,
) -> Result<(), CliError> {
    let now = utc_now();
    let changed = query(
        "UPDATE task_board_dispatch_intents
         SET status = ?2, claim_token = NULL, claimed_at = NULL,
             last_error = ?3,
             updated_at = ?4, completed_at = ?4
         WHERE intent_id = ?1 AND workflow_execution_id = ?5
           AND item_id = ?6 AND status = 'workflow_prepared'",
    )
    .bind(intent_id)
    .bind(if started { "completed" } else { "failed" })
    .bind((!started).then_some("workflow became terminal before target start"))
    .bind(now)
    .bind(&execution.execution_id)
    .bind(&execution.item_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("settle terminal prepared dispatch: {error}")))?
    .rows_affected();
    if changed != 1 {
        return Err(db_error(
            "prepared dispatch changed before terminal admission settlement",
        ));
    }
    Ok(())
}

/// Whether the durably started target released admission directly through
/// its own worker id, rather than through the `!started` failure path.
async fn admission_released_directly_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<bool, CliError> {
    query_scalar::<_, bool>(
        "SELECT EXISTS(
             SELECT 1 FROM task_board_dispatch_admission_ledger
             WHERE intent_id = ?1 AND managed_worker_id = ?2
               AND kind = 'concurrency' AND state = 'released'
         )",
    )
    .bind(intent_id)
    .bind(workflow_owner(&execution.execution_id))
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load terminal start admission release: {error}")))
}
