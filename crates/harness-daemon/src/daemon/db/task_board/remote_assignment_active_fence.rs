use sqlx::{Sqlite, Transaction, query, query_scalar};

#[cfg(test)]
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    TaskBoardRemoteAssignmentState, TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
};

use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, canonical_time, concurrent, to_i64,
};
use super::workflow_executions::load_execution_in_tx;
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TaskBoardAttemptState, TaskBoardExecutionState,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TaskBoardRemoteControllerHandoffKind {
    LocalFallback,
    RemoteReassigned,
    ResultAdopted,
    EvidenceOnly,
    TerminalProjection,
    TerminalCleanup,
}

impl TaskBoardRemoteControllerHandoffKind {
    const fn as_str(self) -> &'static str {
        match self {
            Self::LocalFallback => "local_fallback",
            Self::RemoteReassigned => "remote_reassigned",
            Self::ResultAdopted => "result_adopted",
            Self::EvidenceOnly => "evidence_only",
            Self::TerminalProjection => "terminal_projection",
            Self::TerminalCleanup => "terminal_cleanup",
        }
    }
}

#[cfg(test)]
impl AsyncDaemonDb {
    /// Conservatively fences local work while any unresolved controller generation exists.
    ///
    /// An older claimed worker can still produce side effects after workflow ownership advances,
    /// so only dedicated terminal or fallback settlement releases this execution-wide fence.
    pub(crate) async fn task_board_execution_has_active_remote_assignment(
        &self,
        execution_id: &str,
    ) -> Result<bool, CliError> {
        active_remote_assignment_exists(self, execution_id, None).await
    }

    pub(crate) async fn task_board_execution_generation_has_active_remote_assignment(
        &self,
        execution_id: &str,
        fencing_epoch: u64,
    ) -> Result<bool, CliError> {
        active_remote_assignment_exists(self, execution_id, Some(fencing_epoch)).await
    }
}

#[cfg(test)]
async fn active_remote_assignment_exists(
    db: &AsyncDaemonDb,
    execution_id: &str,
    fencing_epoch: Option<u64>,
) -> Result<bool, CliError> {
    if execution_id.trim().is_empty() {
        return Err(db_error("remote assignment execution id is blank"));
    }
    let epoch = fencing_epoch
        .map(|value| {
            i64::try_from(value)
                .map_err(|_| db_error("remote assignment fencing epoch is out of range"))
        })
        .transpose()?;
    query_scalar::<_, i64>(
        "SELECT EXISTS(
             SELECT 1
             FROM task_board_remote_assignments AS assignments
             JOIN task_board_execution_hosts AS hosts USING (host_id)
             WHERE assignments.execution_id = ?1
               AND (?2 IS NULL OR assignments.fencing_epoch = ?2)
               AND hosts.host_role = 'controller_remote'
               AND assignments.legacy_migrated = 0
               AND NOT COALESCE((
                   (
                       (assignments.controller_handoff_kind = 'local_fallback'
                        AND assignments.state = 'superseded'
                        AND assignments.controller_handoff_successor_assignment_id IS NULL
                        AND assignments.controller_handoff_successor_fencing_epoch IS NULL)
                       OR (assignments.controller_handoff_kind = 'remote_reassigned'
                           AND assignments.state = 'superseded'
                           AND EXISTS (
                               SELECT 1
                               FROM task_board_remote_assignments AS successor
                               WHERE successor.assignment_id =
                                   assignments.controller_handoff_successor_assignment_id
                                 AND successor.fencing_epoch =
                                   assignments.controller_handoff_successor_fencing_epoch
                                 AND successor.execution_id = assignments.execution_id
                                 AND successor.legacy_migrated = 0
                           ))
                       OR (assignments.controller_handoff_kind = 'result_adopted'
                           AND assignments.state IN ('completed', 'failed')
                           AND assignments.controller_handoff_successor_assignment_id IS NULL
                           AND assignments.controller_handoff_successor_fencing_epoch IS NULL)
                       OR (assignments.controller_handoff_kind = 'evidence_only'
                           AND assignments.state IN (
                               'completed', 'failed', 'cancelled', 'unknown'
                           )
                           AND assignments.controller_handoff_successor_assignment_id IS NULL
                           AND assignments.controller_handoff_successor_fencing_epoch IS NULL)
                       OR (assignments.controller_handoff_kind = 'terminal_projection'
                           AND assignments.state IN ('completed', 'failed', 'cancelled')
                           AND assignments.controller_handoff_successor_assignment_id IS NULL
                           AND assignments.controller_handoff_successor_fencing_epoch IS NULL)
                       OR (assignments.controller_handoff_kind = 'terminal_cleanup'
                           AND assignments.state IN (
                               'completed', 'failed', 'cancelled', 'superseded', 'unknown'
                           )
                           AND assignments.cleanup_settlement_request_sha256 IS NOT NULL
                           AND assignments.cleanup_completed_at IS NOT NULL
                           AND assignments.controller_handoff_successor_assignment_id IS NULL
                           AND assignments.controller_handoff_successor_fencing_epoch IS NULL)
                   )
                   AND length(assignments.controller_handoff_execution_sha256) = 64
                   AND assignments.controller_handoff_execution_sha256
                       NOT GLOB '*[^0-9a-f]*'
                   AND length(trim(assignments.controller_handoff_at)) > 0
               ), 0)
         )",
    )
    .bind(execution_id)
    .bind(epoch)
    .fetch_one(db.pool())
    .await
    .map(|exists| exists != 0)
    .map_err(|error| db_error(format!("load active remote assignment fence: {error}")))
}

pub(super) async fn active_remote_assignment_exists_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    execution_id: &str,
) -> Result<bool, CliError> {
    // This is intentionally execution-wide rather than limited to the parent's current epoch.
    // BEGIN IMMEDIATE makes the check decisive against a concurrent assignment insertion.
    query_scalar::<_, i64>(
        "SELECT EXISTS(
             SELECT 1
             FROM task_board_remote_assignments AS assignments
             JOIN task_board_execution_hosts AS hosts USING (host_id)
             WHERE assignments.execution_id = ?1
               AND hosts.host_role = 'controller_remote'
               AND assignments.legacy_migrated = 0
               AND NOT COALESCE((
                   (
                       (assignments.controller_handoff_kind = 'local_fallback'
                        AND assignments.state = 'superseded'
                        AND assignments.controller_handoff_successor_assignment_id IS NULL
                        AND assignments.controller_handoff_successor_fencing_epoch IS NULL)
                       OR (assignments.controller_handoff_kind = 'remote_reassigned'
                           AND assignments.state = 'superseded'
                           AND EXISTS (
                               SELECT 1
                               FROM task_board_remote_assignments AS successor
                               WHERE successor.assignment_id =
                                   assignments.controller_handoff_successor_assignment_id
                                 AND successor.fencing_epoch =
                                   assignments.controller_handoff_successor_fencing_epoch
                                 AND successor.execution_id = assignments.execution_id
                                 AND successor.legacy_migrated = 0
                           ))
                       OR (assignments.controller_handoff_kind = 'result_adopted'
                           AND assignments.state IN ('completed', 'failed')
                           AND assignments.controller_handoff_successor_assignment_id IS NULL
                           AND assignments.controller_handoff_successor_fencing_epoch IS NULL)
                       OR (assignments.controller_handoff_kind = 'evidence_only'
                           AND assignments.state IN (
                               'completed', 'failed', 'cancelled', 'unknown'
                           )
                           AND assignments.controller_handoff_successor_assignment_id IS NULL
                           AND assignments.controller_handoff_successor_fencing_epoch IS NULL)
                       OR (assignments.controller_handoff_kind = 'terminal_projection'
                           AND assignments.state IN ('completed', 'failed', 'cancelled')
                           AND assignments.controller_handoff_successor_assignment_id IS NULL
                           AND assignments.controller_handoff_successor_fencing_epoch IS NULL)
                       OR (assignments.controller_handoff_kind = 'terminal_cleanup'
                           AND assignments.state IN (
                               'completed', 'failed', 'cancelled', 'superseded', 'unknown'
                           )
                           AND assignments.cleanup_settlement_request_sha256 IS NOT NULL
                           AND assignments.cleanup_completed_at IS NOT NULL
                           AND assignments.controller_handoff_successor_assignment_id IS NULL
                           AND assignments.controller_handoff_successor_fencing_epoch IS NULL)
                   )
                   AND length(assignments.controller_handoff_execution_sha256) = 64
                   AND assignments.controller_handoff_execution_sha256
                       NOT GLOB '*[^0-9a-f]*'
                   AND length(trim(assignments.controller_handoff_at)) > 0
               ), 0)
         )",
    )
    .bind(execution_id)
    .fetch_one(transaction.as_mut())
    .await
    .map(|exists| exists != 0)
    .map_err(|error| {
        db_error(format!(
            "load in-transaction remote assignment fence: {error}"
        ))
    })
}

pub(super) async fn record_controller_handoff_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    durable_state: TaskBoardRemoteAssignmentState,
    kind: TaskBoardRemoteControllerHandoffKind,
    execution: &TaskBoardWorkflowExecutionRecord,
    handed_off_at: &str,
) -> Result<(), CliError> {
    if kind == TaskBoardRemoteControllerHandoffKind::RemoteReassigned {
        return Err(db_error(
            "remote reassignment handoff requires exact successor evidence",
        ));
    }
    canonical_time(handed_off_at, "remote controller handoff time")?;
    let execution_sha256 = TaskBoardWorkflowExecutionCas::from(execution).record_sha256;
    let rows = query(
        "UPDATE task_board_remote_assignments
         SET controller_handoff_kind = ?2,
             controller_handoff_execution_sha256 = ?3,
             controller_handoff_successor_assignment_id = NULL,
             controller_handoff_successor_fencing_epoch = NULL,
             controller_handoff_at = ?4
         WHERE assignment_id = ?1 AND fencing_epoch = ?5 AND state = ?6
           AND request_sha256 IS ?7
           AND (
               (
                   controller_handoff_kind IS NULL
                   AND controller_handoff_execution_sha256 IS NULL
                   AND controller_handoff_successor_assignment_id IS NULL
                   AND controller_handoff_successor_fencing_epoch IS NULL
                   AND controller_handoff_at IS NULL
               )
               OR (
                   controller_handoff_kind = ?2
                   AND controller_handoff_execution_sha256 = ?3
                   AND controller_handoff_successor_assignment_id IS NULL
                   AND controller_handoff_successor_fencing_epoch IS NULL
                   AND controller_handoff_at = ?4
               )
           )",
    )
    .bind(&assignment.assignment_id)
    .bind(kind.as_str())
    .bind(execution_sha256)
    .bind(handed_off_at)
    .bind(to_i64(
        assignment.fencing_epoch,
        "remote controller handoff fencing epoch",
    )?)
    .bind(durable_state.as_str())
    .bind(&assignment.request_sha256)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("record remote controller handoff: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent(
            "remote controller handoff lost its exact assignment generation",
        ))
    }
}

pub(super) async fn record_controller_reassignment_handoff_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    predecessor: &TaskBoardRemoteAssignmentRecord,
    successor: &TaskBoardRemoteAssignmentRecord,
    execution: &TaskBoardWorkflowExecutionRecord,
    handed_off_at: &str,
) -> Result<(), CliError> {
    canonical_time(handed_off_at, "remote reassignment handoff time")?;
    if predecessor.execution_id != successor.execution_id
        || successor.fencing_epoch <= predecessor.fencing_epoch
    {
        return Err(concurrent(
            "remote reassignment handoff mismatched its successor generation",
        ));
    }
    let current = load_execution_in_tx(transaction, &predecessor.execution_id)
        .await?
        .ok_or_else(|| concurrent("remote reassignment handoff parent disappeared"))?;
    if TaskBoardWorkflowExecutionCas::from(&current)
        != TaskBoardWorkflowExecutionCas::from(execution)
        || !reassignment_parent_matches(execution, successor)
        || !pristine_reassignment_successor(successor)
    {
        return Err(concurrent(
            "remote reassignment handoff mismatched its exact persisted successor target",
        ));
    }
    let execution_sha256 = TaskBoardWorkflowExecutionCas::from(execution).record_sha256;
    let rows = query(
        "UPDATE task_board_remote_assignments
         SET controller_handoff_kind = 'remote_reassigned',
             controller_handoff_execution_sha256 = ?2,
             controller_handoff_successor_assignment_id = ?3,
             controller_handoff_successor_fencing_epoch = ?4,
             controller_handoff_at = ?5
         WHERE assignment_id = ?1 AND fencing_epoch = ?6 AND state = 'superseded'
           AND request_sha256 IS ?7
           AND controller_handoff_kind IS NULL
           AND controller_handoff_execution_sha256 IS NULL
           AND controller_handoff_successor_assignment_id IS NULL
           AND controller_handoff_successor_fencing_epoch IS NULL
           AND controller_handoff_at IS NULL
           AND EXISTS (
               SELECT 1 FROM task_board_remote_assignments AS successor
               WHERE successor.assignment_id = ?3 AND successor.fencing_epoch = ?4
                 AND successor.execution_id = ?8 AND successor.legacy_migrated = 0
                 AND successor.request_sha256 IS ?9 AND successor.state = 'offered'
                 AND successor.lease_id IS NULL AND successor.claimed_at IS NULL
                 AND successor.started_at IS NULL AND successor.workspace_ref IS NULL
           )",
    )
    .bind(&predecessor.assignment_id)
    .bind(execution_sha256)
    .bind(&successor.assignment_id)
    .bind(to_i64(
        successor.fencing_epoch,
        "remote reassignment successor fencing epoch",
    )?)
    .bind(handed_off_at)
    .bind(to_i64(
        predecessor.fencing_epoch,
        "remote reassignment predecessor fencing epoch",
    )?)
    .bind(&predecessor.request_sha256)
    .bind(&predecessor.execution_id)
    .bind(&successor.request_sha256)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("record remote reassignment handoff: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent(
            "remote reassignment handoff lost its exact predecessor and successor",
        ))
    }
}

fn reassignment_parent_matches(
    execution: &TaskBoardWorkflowExecutionRecord,
    successor: &TaskBoardRemoteAssignmentRecord,
) -> bool {
    let expected_target = format!("remote:{}", successor.assignment_id);
    let expected_attempt = successor.attempt.map(|attempt| attempt.to_string());
    let mut active = execution.attempts.iter().filter(|attempt| {
        matches!(
            attempt.state,
            TaskBoardAttemptState::Preparing
                | TaskBoardAttemptState::Starting
                | TaskBoardAttemptState::Running
        )
    });
    let exact_attempt = active.next().is_some_and(|attempt| {
        attempt.state == TaskBoardAttemptState::Starting
            && successor.action_key.as_ref() == Some(&attempt.action_key)
            && successor.attempt == Some(attempt.attempt)
            && successor.idempotency_key == attempt.idempotency_key
    }) && active.next().is_none();
    execution.transition.execution_state == TaskBoardExecutionState::Starting
        && execution.ownership.host_id.as_deref() == Some(successor.host_id.as_str())
        && execution.ownership.fencing_epoch == successor.fencing_epoch
        && execution
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            == Some(&expected_target)
        && execution
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE)
            == successor.action_key.as_ref()
        && execution
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE)
            .map(String::as_str)
            == expected_attempt.as_deref()
        && exact_attempt
}

fn pristine_reassignment_successor(successor: &TaskBoardRemoteAssignmentRecord) -> bool {
    successor.state == TaskBoardRemoteAssignmentState::Offered
        && successor.controller_operation.is_none()
        && successor.claim_receipt.is_none()
        && successor.lease_id.is_none()
        && successor.claimed_at.is_none()
        && successor.started_at.is_none()
        && successor.workspace_ref.is_none()
        && successor.start_receipt.is_none()
        && successor.executor_start_authority_sha256.is_none()
        && successor.executor_lifecycle_owner.is_none()
        && successor.executor_stop_pending.is_none()
        && successor.status_response.is_none()
        && successor.result_sha256.is_none()
        && successor.cleanup_completed_at.is_none()
}

pub(super) async fn controller_handoff_is_recorded_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Result<bool, CliError> {
    query_scalar::<_, i64>(
        "SELECT EXISTS(
             SELECT 1 FROM task_board_remote_assignments AS current
             WHERE current.assignment_id = ?1 AND current.fencing_epoch = ?2
               AND current.request_sha256 IS ?3
               AND length(current.controller_handoff_execution_sha256) = 64
               AND current.controller_handoff_execution_sha256 NOT GLOB '*[^0-9a-f]*'
               AND length(trim(current.controller_handoff_at)) > 0
               AND (
                   (current.controller_handoff_kind = 'local_fallback'
                    AND current.state = 'superseded'
                    AND current.controller_handoff_successor_assignment_id IS NULL
                    AND current.controller_handoff_successor_fencing_epoch IS NULL)
                   OR (current.controller_handoff_kind = 'remote_reassigned'
                       AND current.state = 'superseded'
                       AND EXISTS (
                           SELECT 1 FROM task_board_remote_assignments AS successor
                           WHERE successor.assignment_id =
                               current.controller_handoff_successor_assignment_id
                             AND successor.fencing_epoch =
                               current.controller_handoff_successor_fencing_epoch
                             AND successor.execution_id = current.execution_id
                             AND successor.legacy_migrated = 0
                       ))
                   OR (current.controller_handoff_kind = 'result_adopted'
                       AND current.state IN ('completed', 'failed')
                       AND current.controller_handoff_successor_assignment_id IS NULL
                       AND current.controller_handoff_successor_fencing_epoch IS NULL)
                   OR (current.controller_handoff_kind = 'evidence_only'
                       AND current.state IN ('completed', 'failed', 'cancelled', 'unknown')
                       AND current.controller_handoff_successor_assignment_id IS NULL
                       AND current.controller_handoff_successor_fencing_epoch IS NULL)
                   OR (current.controller_handoff_kind = 'terminal_projection'
                       AND current.state IN ('completed', 'failed', 'cancelled')
                       AND current.controller_handoff_successor_assignment_id IS NULL
                       AND current.controller_handoff_successor_fencing_epoch IS NULL)
                   OR (current.controller_handoff_kind = 'terminal_cleanup'
                       AND current.state IN (
                           'completed', 'failed', 'cancelled', 'superseded', 'unknown'
                       )
                       AND current.cleanup_settlement_request_sha256 IS NOT NULL
                       AND current.cleanup_completed_at IS NOT NULL
                       AND current.controller_handoff_successor_assignment_id IS NULL
                       AND current.controller_handoff_successor_fencing_epoch IS NULL)
               )
         )",
    )
    .bind(&assignment.assignment_id)
    .bind(to_i64(
        assignment.fencing_epoch,
        "remote controller handoff fencing epoch",
    )?)
    .bind(&assignment.request_sha256)
    .fetch_one(transaction.as_mut())
    .await
    .map(|exists| exists != 0)
    .map_err(|error| db_error(format!("load durable remote controller handoff: {error}")))
}

pub(super) async fn controller_handoff_matches_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    kind: TaskBoardRemoteControllerHandoffKind,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<bool, CliError> {
    let execution_sha256 = TaskBoardWorkflowExecutionCas::from(execution).record_sha256;
    query_scalar::<_, i64>(
        "SELECT EXISTS(
             SELECT 1 FROM task_board_remote_assignments
             WHERE assignment_id = ?1 AND fencing_epoch = ?2
               AND request_sha256 IS ?3 AND controller_handoff_kind = ?4
               AND controller_handoff_execution_sha256 = ?5
               AND controller_handoff_successor_assignment_id IS NULL
               AND controller_handoff_successor_fencing_epoch IS NULL
               AND controller_handoff_at IS NOT NULL
         )",
    )
    .bind(&assignment.assignment_id)
    .bind(to_i64(
        assignment.fencing_epoch,
        "remote controller handoff fencing epoch",
    )?)
    .bind(&assignment.request_sha256)
    .bind(kind.as_str())
    .bind(execution_sha256)
    .fetch_one(transaction.as_mut())
    .await
    .map(|exists| exists != 0)
    .map_err(|error| db_error(format!("load remote controller handoff: {error}")))
}
