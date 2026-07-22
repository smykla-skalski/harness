//! Durable controller classification before executor settlement and cleanup.

use sqlx::{Sqlite, Transaction, query_as, query_scalar};

use super::remote_assignment_active_fence::{
    TaskBoardRemoteControllerHandoffKind, controller_handoff_matches_in_tx,
    record_controller_handoff_in_tx,
};
use super::remote_assignment_lease::{commit_noop, finish_mutation, require_assignment};
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome, canonical_time, concurrent,
    to_i64,
};
use super::workflow_executions::load_execution_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionState, TaskBoardRemoteAssignmentState,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
    task_board_remote_execution_target,
};

impl AsyncDaemonDb {
    pub(crate) async fn record_task_board_remote_terminal_cleanup_handoff(
        &self,
        expected_assignment: &TaskBoardRemoteAssignmentRecord,
        expected_parent: &TaskBoardWorkflowExecutionCas,
        handed_off_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        canonical_time(handed_off_at, "remote terminal cleanup handoff time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote terminal cleanup handoff")
            .await?;
        let assignment =
            require_assignment(&mut transaction, &expected_assignment.assignment_id).await?;
        if assignment != *expected_assignment {
            commit_noop(transaction, "stale terminal cleanup handoff").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(assignment));
        }
        let parent = load_execution_in_tx(&mut transaction, &assignment.execution_id)
            .await?
            .ok_or_else(|| concurrent("remote terminal cleanup parent disappeared"))?;
        if TaskBoardWorkflowExecutionCas::from(&parent) != *expected_parent {
            commit_noop(transaction, "stale terminal cleanup parent").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(assignment));
        }
        if terminal_cleanup_handoff_matches_in_tx(&mut transaction, &assignment, &parent).await? {
            commit_noop(transaction, "replayed terminal cleanup handoff").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Replayed(assignment));
        }
        require_terminal_cleanup_candidate(&assignment, &parent)?;
        record_controller_handoff_in_tx(
            &mut transaction,
            &assignment,
            assignment.state,
            TaskBoardRemoteControllerHandoffKind::TerminalCleanup,
            &parent,
            handed_off_at,
        )
        .await?;
        finish_mutation(
            transaction,
            &assignment.assignment_id,
            "terminal cleanup handoff",
        )
        .await
    }

    pub(crate) async fn task_board_remote_assignment_has_settlement_handoff(
        &self,
        assignment_id: &str,
        fencing_epoch: u64,
    ) -> Result<bool, CliError> {
        let mut transaction =
            self.pool().begin().await.map_err(|error| {
                db_error(format!("begin remote settlement handoff read: {error}"))
            })?;
        let assignment = require_assignment(&mut transaction, assignment_id).await?;
        let recorded = assignment.fencing_epoch == fencing_epoch
            && terminal_handoff_digest_in_tx(&mut transaction, &assignment)
                .await?
                .is_some();
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote settlement handoff read: {error}")))?;
        Ok(recorded)
    }
}

pub(super) async fn settlement_handoff_exists_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Result<bool, CliError> {
    Ok(terminal_handoff_digest_in_tx(transaction, assignment)
        .await?
        .is_some())
}

pub(super) async fn terminal_handoff_digest_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Result<Option<String>, CliError> {
    if assignment.legacy_migrated {
        return Ok(None);
    }
    let allowed = match assignment.state {
        TaskBoardRemoteAssignmentState::Completed | TaskBoardRemoteAssignmentState::Failed => {
            ("result_adopted", Some("evidence_only"), None)
        }
        TaskBoardRemoteAssignmentState::Unknown => ("evidence_only", None, None),
        TaskBoardRemoteAssignmentState::Cancelled => (
            "evidence_only",
            Some("terminal_cleanup"),
            Some("terminal_projection"),
        ),
        TaskBoardRemoteAssignmentState::Superseded => {
            ("terminal_cleanup", Some("terminal_projection"), None)
        }
        TaskBoardRemoteAssignmentState::Offered
        | TaskBoardRemoteAssignmentState::Claimed
        | TaskBoardRemoteAssignmentState::Started
        | TaskBoardRemoteAssignmentState::Running => return Ok(None),
    };
    let handoff = query_as::<_, (String, String)>(
        "SELECT controller_handoff_execution_sha256, controller_handoff_at
         FROM task_board_remote_assignments
         WHERE assignment_id = ?1 AND fencing_epoch = ?2
           AND request_sha256 IS ?3
           AND controller_handoff_kind IN (?4, ?5, ?6)
           AND length(controller_handoff_execution_sha256) = 64
           AND controller_handoff_execution_sha256 NOT GLOB '*[^0-9a-f]*'
           AND controller_handoff_successor_assignment_id IS NULL
           AND controller_handoff_successor_fencing_epoch IS NULL
           AND controller_handoff_at IS NOT NULL",
    )
    .bind(&assignment.assignment_id)
    .bind(to_i64(
        assignment.fencing_epoch,
        "durable terminal handoff fencing epoch",
    )?)
    .bind(&assignment.request_sha256)
    .bind(allowed.0)
    .bind(allowed.1)
    .bind(allowed.2)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load durable terminal handoff: {error}")))?;
    let Some((digest, handed_off_at)) = handoff else {
        return Ok(None);
    };
    canonical_time(&handed_off_at, "durable terminal handoff time")?;
    Ok(Some(digest))
}

async fn terminal_cleanup_or_projection_matches_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
) -> Result<bool, CliError> {
    if controller_handoff_matches_in_tx(
        transaction,
        assignment,
        TaskBoardRemoteControllerHandoffKind::TerminalCleanup,
        parent,
    )
    .await?
    {
        return Ok(true);
    }
    controller_handoff_matches_in_tx(
        transaction,
        assignment,
        TaskBoardRemoteControllerHandoffKind::TerminalProjection,
        parent,
    )
    .await
}

pub(super) async fn terminal_cleanup_handoff_matches_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
) -> Result<bool, CliError> {
    let parent_sha256 = TaskBoardWorkflowExecutionCas::from(parent).record_sha256;
    query_scalar::<_, i64>(
        "SELECT EXISTS(
             SELECT 1 FROM task_board_remote_assignments
             WHERE assignment_id = ?1 AND fencing_epoch = ?2
               AND request_sha256 IS ?3
               AND controller_handoff_kind = 'terminal_cleanup'
               AND controller_handoff_execution_sha256 = ?4
               AND controller_handoff_successor_assignment_id IS NULL
               AND controller_handoff_successor_fencing_epoch IS NULL
               AND controller_handoff_at IS NOT NULL
         )",
    )
    .bind(&assignment.assignment_id)
    .bind(to_i64(
        assignment.fencing_epoch,
        "terminal cleanup handoff fencing epoch",
    )?)
    .bind(&assignment.request_sha256)
    .bind(parent_sha256)
    .fetch_one(transaction.as_mut())
    .await
    .map(|recorded| recorded != 0)
    .map_err(|error| db_error(format!("load terminal cleanup handoff: {error}")))
}

/// A pending terminal-cleanup classification, independent of the parent generation
/// it was recorded against. Cleanup completion runs in a later controller cycle than
/// the classification, so the detached parent may have advanced; the handoff is
/// immutable historical evidence and must be recognized (and preserved) regardless.
fn require_terminal_cleanup_candidate(
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), CliError> {
    if !matches!(
        assignment.state,
        TaskBoardRemoteAssignmentState::Cancelled | TaskBoardRemoteAssignmentState::Superseded
    ) || parent_points_to_assignment(parent, assignment)
    {
        return Err(concurrent(
            "remote terminal cleanup handoff requires a detached terminal generation",
        ));
    }
    Ok(())
}

pub(crate) fn exact_active_remote_target(
    parent: &TaskBoardWorkflowExecutionRecord,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> bool {
    let Some(offer) = assignment.offer.as_ref() else {
        return false;
    };
    if !matches!(
        parent.transition.execution_state,
        TaskBoardExecutionState::Starting | TaskBoardExecutionState::Running
    ) || !super::remote_assignment_io_authority::active_target_matches(parent, assignment)
    {
        return false;
    }
    let mut active = parent.attempts.iter().filter(|attempt| {
        matches!(
            attempt.state,
            TaskBoardAttemptState::Preparing
                | TaskBoardAttemptState::Starting
                | TaskBoardAttemptState::Running
        )
    });
    active.next().is_some_and(|attempt| {
        attempt.action_key == offer.binding.action_key
            && attempt.attempt == offer.binding.attempt
            && attempt.idempotency_key == offer.binding.idempotency_key
            && matches!(
                attempt.state,
                TaskBoardAttemptState::Starting | TaskBoardAttemptState::Running
            )
    }) && active.next().is_none()
}

pub(crate) fn parent_points_to_assignment(
    parent: &TaskBoardWorkflowExecutionRecord,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> bool {
    task_board_remote_execution_target(parent) == Some(assignment.assignment_id.as_str())
}
