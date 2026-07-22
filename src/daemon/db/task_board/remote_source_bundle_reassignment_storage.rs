use sqlx::{Sqlite, Transaction, query, query_scalar};

use super::super::remote_assignment_model::{TaskBoardRemoteAssignmentRecord, concurrent, to_i64};
use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest;

const REASSIGNMENT_REASON: &str = "source_bundle_absent_after_executor_restart";

pub(super) async fn supersede_predecessor_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    predecessor: &TaskBoardRemoteAssignmentRecord,
    now: &str,
) -> Result<(), CliError> {
    let rows = query(
        "UPDATE task_board_remote_assignments SET state = 'superseded',
         completed_at = ?3, error = ?4, updated_at = ?3
         WHERE assignment_id = ?1 AND fencing_epoch = ?2 AND state = 'offered'
           AND request_sha256 = ?5 AND updated_at = ?6
           AND lease_id IS NULL AND claimed_at IS NULL AND started_at IS NULL
           AND workspace_ref IS NULL AND claim_receipt_sha256 IS NULL
           AND controller_operation_kind IS NULL
           AND executor_start_authority_sha256 IS NULL
           AND executor_start_receipt_sha256 IS NULL
           AND executor_lifecycle_owner_sha256 IS NULL
           AND executor_stop_pending_sha256 IS NULL
           AND status_sha256 IS NULL AND result_sha256 IS NULL",
    )
    .bind(&predecessor.assignment_id)
    .bind(to_i64(
        predecessor.fencing_epoch,
        "source reassignment predecessor epoch",
    )?)
    .bind(now)
    .bind(REASSIGNMENT_REASON)
    .bind(&predecessor.request_sha256)
    .bind(&predecessor.updated_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("supersede predecessor source offer: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent(
            "source reassignment predecessor changed before supersession",
        ))
    }
}

pub(super) async fn require_no_replacement_collision_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    predecessor: &TaskBoardRemoteAssignmentRecord,
    replacement: &RemoteOfferRequest,
) -> Result<(), CliError> {
    let collision = query_scalar::<_, bool>(
        "SELECT EXISTS(
           SELECT 1 FROM task_board_remote_assignments
           WHERE assignment_id != ?1 AND (
             assignment_id = ?2 OR request_sha256 = ?3
             OR (execution_id = ?4 AND fencing_epoch = ?5)
             OR (
               execution_id = ?4 AND action_key = ?6 AND attempt = ?7
               AND state IN ('offered', 'claimed', 'started', 'running', 'unknown')
             )
             OR (
               idempotency_key = ?8
               AND state IN ('offered', 'claimed', 'started', 'running', 'unknown')
             )
           )
         )",
    )
    .bind(&predecessor.assignment_id)
    .bind(&replacement.binding.assignment_id)
    .bind(&replacement.request_sha256)
    .bind(&replacement.binding.execution_id)
    .bind(to_i64(
        replacement.binding.fencing_epoch,
        "replacement collision fencing epoch",
    )?)
    .bind(&replacement.binding.action_key)
    .bind(i64::from(replacement.binding.attempt))
    .bind(&replacement.binding.idempotency_key)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("check replacement source collision: {error}")))?;
    if collision {
        Err(concurrent(
            "replacement source offer conflicts with durable state",
        ))
    } else {
        Ok(())
    }
}
