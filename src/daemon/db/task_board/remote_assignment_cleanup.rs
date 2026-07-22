use sqlx::{Sqlite, Transaction, query, query_scalar};

use super::remote_assignment_lease::{commit_noop, finish_mutation, require_assignment};
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome, canonical_time, concurrent,
    nonblank, to_i64,
};
use super::remote_settlement_receipts::{load_settlement_in_tx, require_exact_terminal_assignment};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::RemoteSettledRequest;

impl AsyncDaemonDb {
    pub(crate) async fn complete_task_board_remote_assignment_cleanup(
        &self,
        request: &RemoteSettledRequest,
        authenticated_principal: &str,
        completed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote cleanup request: {error}")))?;
        nonblank(authenticated_principal, "remote cleanup principal")?;
        canonical_time(completed_at, "remote cleanup completion time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote cleanup completion")
            .await?;
        let assignment =
            require_assignment(&mut transaction, &request.binding.assignment_id).await?;
        if !persist_cleanup_completion_in_tx(
            &mut transaction,
            &assignment,
            request,
            authenticated_principal,
            completed_at,
        )
        .await?
        {
            commit_noop(transaction, "replayed remote cleanup completion").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Replayed(assignment));
        }
        finish_mutation(transaction, &assignment.assignment_id, "cleanup completion").await
    }

    pub(crate) async fn task_board_remote_executor_active_assignment_count(
        &self,
        host_id: &str,
    ) -> Result<u32, CliError> {
        nonblank(host_id, "remote executor host")?;
        let mut transaction =
            self.pool().begin().await.map_err(|error| {
                db_error(format!("begin remote executor active count: {error}"))
            })?;
        let count = active_remote_assignments_in_tx(&mut transaction, host_id).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote executor active count: {error}")))?;
        Ok(count)
    }
}

pub(super) async fn persist_cleanup_completion_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteSettledRequest,
    authenticated_principal: &str,
    completed_at: &str,
) -> Result<bool, CliError> {
    require_exact_terminal_assignment(assignment, request, authenticated_principal)?;
    if let Some(stored_digest) = assignment.cleanup_settlement_request_sha256.as_deref() {
        if stored_digest == request.request_sha256 && assignment.cleanup_completed_at.is_some() {
            return Ok(false);
        }
        return Err(concurrent(
            "remote cleanup conflicts with its durable settlement marker",
        ));
    }
    let receipt = load_settlement_in_tx(transaction, &assignment.assignment_id)
        .await?
        .ok_or_else(|| concurrent("remote cleanup requires an immutable settlement receipt"))?;
    if !receipt.is_exact_replay(request, authenticated_principal) {
        return Err(concurrent(
            "remote cleanup does not match its immutable settlement receipt",
        ));
    }
    require_cleanup_time(assignment, &receipt.cleanup_ready_at, completed_at)?;
    let rows = query(
        "UPDATE task_board_remote_assignments
         SET cleanup_settlement_request_sha256 = ?2,
             cleanup_completed_at = ?3, updated_at = ?3
         WHERE assignment_id = ?1 AND fencing_epoch = ?4
           AND cleanup_settlement_request_sha256 IS NULL
           AND cleanup_completed_at IS NULL
           AND state IN ('completed', 'failed', 'cancelled', 'superseded', 'unknown')
           AND EXISTS (
             SELECT 1 FROM task_board_remote_settlement_receipts AS receipt
             WHERE receipt.assignment_id = ?1 AND receipt.fencing_epoch = ?4
               AND receipt.request_sha256 = ?2
               AND receipt.authenticated_principal = ?5
           )",
    )
    .bind(&assignment.assignment_id)
    .bind(&request.request_sha256)
    .bind(completed_at)
    .bind(to_i64(
        assignment.fencing_epoch,
        "cleanup assignment fencing epoch",
    )?)
    .bind(authenticated_principal)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("persist remote cleanup completion: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(true)
    } else {
        Err(concurrent("remote cleanup completion lost its exact fence"))
    }
}

pub(super) async fn active_remote_assignments_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    host_id: &str,
) -> Result<u32, CliError> {
    let count = query_scalar::<_, i64>(
        // Legacy-migrated rows can never receive a cleanup marker, so they would
        // otherwise pin capacity forever once their host_id is current again.
        "SELECT COUNT(*) FROM task_board_remote_assignments
         WHERE host_id = ?1 AND legacy_migrated = 0 AND cleanup_completed_at IS NULL AND (
           state IN ('offered', 'claimed', 'started', 'running')
           OR (
             state IN ('completed', 'failed', 'cancelled', 'superseded', 'unknown')
             AND claimed_at IS NOT NULL
           )
         )",
    )
    .bind(host_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("count active remote executor assignments: {error}")))?;
    u32::try_from(count).map_err(|_| db_error("remote executor assignment count is out of range"))
}

pub(super) fn validate_cleanup_marker(
    legacy_migrated: bool,
    state: &str,
    settlement_request_sha256: Option<&str>,
    completed_at: Option<&str>,
) -> Result<(), CliError> {
    match (settlement_request_sha256, completed_at) {
        (None, None) => Ok(()),
        (Some(digest), Some(completed_at))
            if !legacy_migrated
                && matches!(
                    state,
                    "completed" | "failed" | "cancelled" | "superseded" | "unknown"
                )
                && digest.len() == 64
                && digest
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)) =>
        {
            canonical_time(completed_at, "remote cleanup completion time").map(|_| ())
        }
        _ => Err(db_error("remote assignment cleanup marker is inconsistent")),
    }
}

fn require_cleanup_time(
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    cleanup_ready_at: &str,
    completed_at: &str,
) -> Result<(), CliError> {
    let completed = canonical_time(completed_at, "remote cleanup completion time")?;
    let ready = canonical_time(cleanup_ready_at, "remote cleanup ready time")?;
    let assignment_updated =
        canonical_time(&assignment.updated_at, "remote assignment update time")?;
    if completed >= ready && completed >= assignment_updated {
        Ok(())
    } else {
        Err(concurrent(
            "remote cleanup completion predates its terminal settlement evidence",
        ))
    }
}
