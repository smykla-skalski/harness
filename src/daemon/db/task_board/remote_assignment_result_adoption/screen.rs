use sqlx::{Sqlite, Transaction};

use super::{
    TaskBoardRemoteResultAdoptionOutcome, completed_implementation, require_active_adoption_target,
    terminal_adoption_replay_matches,
};
use crate::daemon::db::CliError;
use crate::daemon::db::task_board::remote_assignment_active_fence::{
    TaskBoardRemoteControllerHandoffKind, controller_handoff_matches_in_tx,
};
use crate::daemon::db::task_board::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, concurrent, load_assignment_in_tx,
};
use crate::daemon::db::task_board::remote_result_import::require_adopted_remote_implementation_import_in_tx;
use crate::daemon::db::task_board::workflow_executions::{cas_mismatch, load_execution_in_tx};
use crate::task_board::{
    TaskBoardExecutionAttemptRecord, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord,
};

/// What a screened terminal adoption leaves for its caller to do.
pub(super) enum TerminalAdoptionScreen {
    /// Already decided; `context` names the commit for the no-op that settles
    /// it, matching the dispositions the recorder reported before the split.
    Settled {
        context: &'static str,
        outcome: TaskBoardRemoteResultAdoptionOutcome,
    },
    /// Must stay boxed. It carries the assignment, the parent execution and the
    /// attempt together, and unboxed that measures 19056 bytes inside
    /// `adopt_task_board_remote_terminal_result`, over the 16384-byte threshold
    /// of `clippy::large_futures`, which is denied here. `cargo check` will not
    /// tell you, because the limit is a lint rather than a compile error.
    Proceed(Box<ProceedingAdoption>),
}

/// The records an adoption proved it may write.
pub(super) struct ProceedingAdoption {
    pub(super) assignment: TaskBoardRemoteAssignmentRecord,
    pub(super) parent: TaskBoardWorkflowExecutionRecord,
    pub(super) current_attempt: TaskBoardExecutionAttemptRecord,
    pub(super) attempt_index: usize,
}

/// Decide a terminal result adoption without writing the adoption itself.
pub(super) async fn screen_terminal_adoption_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &TaskBoardWorkflowExecutionCas,
    assignment_id: &str,
    fencing_epoch: u64,
) -> Result<TerminalAdoptionScreen, CliError> {
    let assignment = load_assignment_in_tx(transaction, assignment_id)
        .await?
        .ok_or_else(|| concurrent("remote result assignment disappeared"))?;
    let parent = load_execution_in_tx(transaction, &assignment.execution_id)
        .await?
        .ok_or_else(|| concurrent("remote result execution disappeared"))?;
    if replayed_terminal_adoption_in_tx(transaction, &assignment, &parent, fencing_epoch).await? {
        return Ok(TerminalAdoptionScreen::Settled {
            context: "replayed",
            outcome: TaskBoardRemoteResultAdoptionOutcome::Replayed(parent),
        });
    }
    if assignment.fencing_epoch != fencing_epoch || cas_mismatch(expected, &parent).is_some() {
        return Ok(TerminalAdoptionScreen::Settled {
            context: "stale",
            outcome: TaskBoardRemoteResultAdoptionOutcome::Stale(parent),
        });
    }
    let (attempt_index, current_attempt) = require_active_adoption_target(&assignment, &parent)?;
    Ok(TerminalAdoptionScreen::Proceed(Box::new(
        ProceedingAdoption {
            assignment,
            parent,
            current_attempt,
            attempt_index,
        },
    )))
}

/// Whether this adoption already happened under the same generation, and, when
/// it did, that the implementation import it depends on is durable.
///
/// The import check stays inside the replay verdict: it only means anything for
/// a replay, and reporting the replay without it would let a caller treat a
/// half-imported adoption as complete.
async fn replayed_terminal_adoption_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
    fencing_epoch: u64,
) -> Result<bool, CliError> {
    let replayed = assignment.fencing_epoch == fencing_epoch
        && terminal_adoption_replay_matches(assignment, parent)
        && controller_handoff_matches_in_tx(
            transaction,
            assignment,
            TaskBoardRemoteControllerHandoffKind::ResultAdopted,
            parent,
        )
        .await?;
    if replayed && completed_implementation(assignment) {
        require_adopted_remote_implementation_import_in_tx(transaction, assignment).await?;
    }
    Ok(replayed)
}
