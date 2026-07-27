use sqlx::{Sqlite, Transaction};

use super::triage_apply::{TriageOutcome, apply_placement_effect_in_tx, placement_matches_verdict};
use crate::daemon::db::CliError;
use crate::task_board::{TaskBoardItem, TaskBoardLaneOrigin, TaskBoardTriageDecision};

/// Settle the placement effect when there was nothing new to decide (same
/// evaluator, same evidence). A genuinely unchanged item is a true no-op, but
/// an out-of-band mutation in this same call (a provider-exclusion restore
/// resetting status independent of triage, for example) can leave the item's
/// placement out of sync with the existing, unchanged decision. Reapply that
/// decision's placement without appending a new history generation, so a
/// restore never strands a prior Todo verdict unranked or in Inbox; a
/// genuinely unchanged item still reports no decision at all.
///
/// The retained decision's own evaluator identity is the correct placement
/// producer here, not the caller's active evaluator -- a retained `AGENT_V1`
/// decision must re-apply placement under `AGENT_V1`, or every later touch
/// churns it back through `BuiltInV1`'s identity (the #334 F1 lesson,
/// generalized). Every evaluator's ingress path shares this one arm rather
/// than restating it, so that rule cannot drift per evaluator.
pub(super) async fn retained_effect_outcome_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    existing: Option<TaskBoardTriageDecision>,
    decided_at: &str,
    suppress_placement: bool,
    override_active: bool,
) -> Result<Option<TriageOutcome>, CliError> {
    let Some(existing) = existing else {
        return Ok(None);
    };
    if placement_matches_verdict(item, existing.verdict, &existing.evaluator_identity) {
        return Ok(None);
    }
    let manually_placed = item
        .lane_origin
        .as_ref()
        .is_some_and(TaskBoardLaneOrigin::is_manual);
    if manually_placed || suppress_placement || override_active {
        // The desync is real, but a manual anchor or a direct human/provider
        // effect this same call means the effect never actually runs --
        // reporting `RetainedEffect` here would audit something that did not
        // happen. The enclosing mutation still gets its own ordinary audit.
        return Ok(None);
    }
    let producer = existing.evaluator_identity.clone();
    apply_placement_effect_in_tx(transaction, item, existing.verdict, decided_at, &producer)
        .await?;
    Ok(Some(TriageOutcome::RetainedEffect(existing)))
}
