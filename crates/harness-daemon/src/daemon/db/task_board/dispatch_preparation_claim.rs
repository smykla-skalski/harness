use sqlx::{Sqlite, Transaction, query_as};

use super::dispatch_preparations::ClaimedTaskBoardDispatchPreparation;
use crate::daemon::db::{CliError, db_error};

/// Why a preparation could not be claimed. The recovery loop treats every
/// variant the same way - there is nothing to do this tick - but the
/// interactive dispatch path reports it, and reporting contention for all of
/// them hid the failure a retrying preparation was stuck on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TaskBoardPreparationUnavailable {
    /// No intent with that id.
    Missing,
    /// Another worker holds a live lease on it.
    HeldByWorker,
    /// Re-armed after a failed attempt and still inside its backoff.
    WaitingToRetry {
        seconds_remaining: i64,
        last_error: Option<String>,
    },
    /// Already left the preparing states: prepared, running, or terminal.
    Settled { status: String },
}

#[derive(Debug)]
pub(crate) enum TaskBoardPreparationClaim {
    Claimed(Box<ClaimedTaskBoardDispatchPreparation>),
    Unavailable(TaskBoardPreparationUnavailable),
}

impl TaskBoardPreparationClaim {
    pub(crate) fn claimed(self) -> Option<ClaimedTaskBoardDispatchPreparation> {
        match self {
            Self::Claimed(claim) => Some(*claim),
            Self::Unavailable(_) => None,
        }
    }
}

/// Reads why `intent_id` was not claimable. Runs inside the screening
/// transaction so the reason describes the same row the claim just missed
/// rather than whatever the row became afterwards.
pub(super) async fn classify_unavailable_preparation_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<TaskBoardPreparationUnavailable, CliError> {
    let row = query_as::<_, (String, Option<String>, Option<i64>)>(
        "SELECT status, last_error,
                CAST(strftime('%s', available_at) - strftime('%s', 'now') AS INTEGER)
         FROM task_board_dispatch_intents WHERE intent_id = ?1",
    )
    .bind(intent_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("classify task board preparation claim: {error}")))?;
    let Some((status, last_error, seconds_remaining)) = row else {
        return Ok(TaskBoardPreparationUnavailable::Missing);
    };
    Ok(match status.as_str() {
        // Expired leases are returned to the queue before this runs, so a row
        // still claimed here belongs to a worker that is genuinely working.
        "preparing_claimed" => TaskBoardPreparationUnavailable::HeldByWorker,
        "preparing" => TaskBoardPreparationUnavailable::WaitingToRetry {
            seconds_remaining: seconds_remaining.unwrap_or_default().max(0),
            last_error,
        },
        _ => TaskBoardPreparationUnavailable::Settled { status },
    })
}
