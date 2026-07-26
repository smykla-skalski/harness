//! The atomic workflow-execution-and-attempt CAS: what the compare decides,
//! and the write that follows from it. `workflow_execution_attempts.rs` owns
//! the transaction and commits exactly once, whichever way the compare goes.

use sqlx::{Sqlite, Transaction};

use super::super::ORCHESTRATOR_CHANGE_SCOPE;
use super::super::items::bump_change_in_tx;
use super::super::remote_assignment_stop_fence::{
    RemoteTargetStopPlan, remote_target_stop_plan_in_tx,
};
use super::super::workflow_executions::{
    cas_mismatch, load_execution_in_tx, update_execution_in_tx,
};
use super::{
    attempt_cas_matches, reject_active_remote_target_mutation, update_attempt_in_tx,
    validate_atomic_execution_attempt_update,
};
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptRecord, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord,
};

/// The four records the atomic CAS compares against each other. Every step of
/// the CAS reads all of them and none of them changes.
pub(super) struct AtomicCasExpectation<'a> {
    pub(super) execution: &'a TaskBoardWorkflowExecutionCas,
    pub(super) updated_execution: &'a TaskBoardWorkflowExecutionRecord,
    pub(super) attempt: &'a TaskBoardExecutionAttemptCas,
    pub(super) updated_attempt: &'a TaskBoardExecutionAttemptRecord,
}

/// What the compare decided. Every variant ends in the caller's single commit
/// and differs only in what is left to write and what the CAS reports.
pub(super) enum AtomicCasSettlement {
    /// Nothing left to write: the row is missing, stale, unchanged, or a
    /// remote cancellation this CAS had already persisted was replayed.
    /// `context` is the commit's error context, which names which of those it
    /// was.
    Settled {
        context: &'static str,
        result: Option<Box<TaskBoardWorkflowExecutionRecord>>,
    },
    /// The stop is deferred to a remote cancel intent, so only the parent
    /// execution it carries is stored and the attempt update is dropped.
    PersistCancelIntent(Box<TaskBoardWorkflowExecutionRecord>),
    Apply(Box<AtomicCasApply>),
}

pub(super) struct AtomicCasApply {
    current: TaskBoardWorkflowExecutionRecord,
    current_attempt: TaskBoardExecutionAttemptRecord,
    combined: TaskBoardWorkflowExecutionRecord,
}

/// Compares the stored execution and attempt against `expectation` and works
/// out how the CAS ends. Not a pure read: the remote stop plan it consults
/// supersedes an unclaimed remote offer itself when the workflow stops before
/// that offer was ever claimed.
pub(super) async fn decide_atomic_cas_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expectation: &AtomicCasExpectation<'_>,
) -> Result<AtomicCasSettlement, CliError> {
    let Some(current) =
        load_execution_in_tx(transaction, &expectation.execution.execution_id).await?
    else {
        return Ok(settled("missing workflow execution and attempt CAS", None));
    };
    let Some((attempt_index, current_attempt)) = current
        .attempts
        .iter()
        .enumerate()
        .find(|(_, attempt)| {
            attempt.action_key == expectation.attempt.action_key
                && attempt.attempt == expectation.attempt.attempt
        })
        .map(|(index, attempt)| (index, attempt.clone()))
    else {
        return Ok(settled(
            "missing attempt workflow execution and attempt CAS",
            None,
        ));
    };
    if cas_mismatch(expectation.execution, &current).is_some()
        || !attempt_cas_matches(expectation.attempt, &current_attempt)
    {
        return Ok(settled("stale workflow execution and attempt CAS", None));
    }
    let mut combined = expectation.updated_execution.clone();
    let attempt = combined
        .attempts
        .get_mut(attempt_index)
        .ok_or_else(|| db_error("atomic execution update removed its expected attempt"))?;
    *attempt = expectation.updated_attempt.clone();
    if combined == current {
        return Ok(settled(
            "unchanged workflow execution and attempt CAS",
            Some(current),
        ));
    }
    validate_atomic_execution_attempt_update(
        &current,
        expectation.updated_execution,
        &current_attempt,
        expectation.updated_attempt,
        &combined,
    )?;
    match remote_target_stop_plan_in_tx(transaction, &current, &combined).await? {
        RemoteTargetStopPlan::PersistCancelIntent(parent) => {
            Ok(AtomicCasSettlement::PersistCancelIntent(Box::new(parent)))
        }
        RemoteTargetStopPlan::ReplayedCancelIntent(parent) => Ok(settled(
            "replayed remote cancellation workflow execution and attempt CAS",
            Some(parent),
        )),
        RemoteTargetStopPlan::ApplyRequested => {
            Ok(AtomicCasSettlement::Apply(Box::new(AtomicCasApply {
                current,
                current_attempt,
                combined,
            })))
        }
    }
}

fn settled(
    context: &'static str,
    result: Option<TaskBoardWorkflowExecutionRecord>,
) -> AtomicCasSettlement {
    AtomicCasSettlement::Settled {
        context,
        result: result.map(Box::new),
    }
}

/// Writes whatever the settlement still owes and returns the commit's error
/// context together with what the CAS reports.
pub(super) async fn apply_atomic_cas_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expectation: &AtomicCasExpectation<'_>,
    settlement: AtomicCasSettlement,
) -> Result<(&'static str, Option<TaskBoardWorkflowExecutionRecord>), CliError> {
    match settlement {
        AtomicCasSettlement::Settled { context, result } => {
            Ok((context, result.map(|record| *record)))
        }
        AtomicCasSettlement::PersistCancelIntent(parent) => {
            persist_deferred_cancellation_in_tx(transaction, expectation.execution, &parent)
                .await?;
            Ok(("deferred remote cancellation CAS", Some(*parent)))
        }
        AtomicCasSettlement::Apply(apply) => {
            let combined =
                apply_execution_and_attempt_in_tx(transaction, expectation, *apply).await?;
            Ok((
                "task board workflow execution and attempt CAS",
                Some(combined),
            ))
        }
    }
}

async fn persist_deferred_cancellation_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &TaskBoardWorkflowExecutionCas,
    parent: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), CliError> {
    update_execution_in_tx(transaction, expected, parent).await?;
    bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    Ok(())
}

async fn apply_execution_and_attempt_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expectation: &AtomicCasExpectation<'_>,
    apply: AtomicCasApply,
) -> Result<TaskBoardWorkflowExecutionRecord, CliError> {
    let AtomicCasApply {
        current,
        current_attempt,
        combined,
    } = apply;
    reject_active_remote_target_mutation(&current, &current_attempt)?;
    update_execution_in_tx(transaction, expectation.execution, &combined).await?;
    update_attempt_in_tx(
        transaction,
        expectation.attempt,
        expectation.updated_attempt,
    )
    .await?;
    bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    Ok(combined)
}
