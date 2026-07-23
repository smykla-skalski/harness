use sqlx::{Sqlite, Transaction};

use super::lane_order::load_lane_entries_in_tx;
use super::triage_decisions::{current_triage_decision_in_tx, record_triage_decision_in_tx};
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    BUILTIN_V1_EVALUATOR_IDENTITY, BUILTIN_V1_EVALUATOR_VERSION, TaskBoardItem,
    TaskBoardLaneOrigin, TaskBoardStatus, TaskBoardTriageDecision, TriageCause, TriageVerdict,
    evaluate_builtin_v1, evidence_fingerprint, sort_task_board_items,
};

/// Only dispatchable, live, unlinked, pre-dispatch items are `BuiltInV1`'s
/// business. Everything else (umbrellas, tombstones, already-dispatched
/// items, and items past Backlog/Todo) gets no decision at all.
fn triage_eligible(item: &TaskBoardItem) -> bool {
    item.kind.is_dispatchable()
        && !item.is_deleted()
        && item.work_item_id.is_none()
        && matches!(
            item.status.canonical_persisted_status(),
            TaskBoardStatus::Backlog | TaskBoardStatus::Todo
        )
}

/// Distinguishes a freshly recorded `BuiltInV1` decision (a new history
/// generation) from an existing decision whose placement effect was merely
/// reapplied (no new generation) -- callers must never audit the latter as
/// `triage_decided`.
#[derive(Debug)]
pub(super) enum TriageOutcome {
    Decided(TaskBoardTriageDecision),
    RetainedEffect(TaskBoardTriageDecision),
}

impl TriageOutcome {
    pub(super) const fn decision(&self) -> &TaskBoardTriageDecision {
        match self {
            Self::Decided(decision) | Self::RetainedEffect(decision) => decision,
        }
    }
}

/// Evaluate and, where warranted, apply the `BuiltInV1` deterministic triage
/// check table against `item` in place, inside the caller's ongoing
/// transaction. Mutates `item.status`/`lane_position`/`lane_origin`/
/// `lane_set_at` for a Backlog-to-Todo promotion, a Todo-to-Backlog demotion,
/// or a re-rank of an already-Todo item whose priority (or other ranked
/// evidence) changed. `suppress_placement` covers a direct human or provider
/// effect on status/placement within the very same mutation (a plain manual
/// `lane_origin` anchor is checked independently below); either one still
/// lets the decision itself refresh. Returns `None` when the item is
/// ineligible or the decision is unchanged (idempotent).
pub(super) async fn apply_builtin_v1_triage_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    decided_at: &str,
    suppress_placement: bool,
) -> Result<Option<TriageOutcome>, CliError> {
    if !triage_eligible(item) {
        return Ok(None);
    }
    let fingerprint = evidence_fingerprint(item);
    let existing = current_triage_decision_in_tx(transaction, &item.id).await?;
    let Some(cause) = triage_cause(existing.as_ref(), &fingerprint) else {
        // Nothing new to decide (same evaluator, same evidence). A genuinely
        // unchanged item is a true no-op, but an out-of-band mutation in
        // this same call (a provider-exclusion restore resetting status
        // independent of triage, for example) can leave the item's
        // placement out of sync with the existing, unchanged decision.
        // Reapply that decision's placement without appending a new history
        // generation, so a restore never strands a prior Todo verdict
        // unranked or in Backlog; a genuinely unchanged item still reports
        // no decision at all.
        return match existing {
            Some(existing) if !placement_matches_verdict(item, existing.verdict) => {
                let manually_placed = item
                    .lane_origin
                    .as_ref()
                    .is_some_and(TaskBoardLaneOrigin::is_manual);
                if manually_placed || suppress_placement {
                    // The desync is real, but a manual anchor or a direct
                    // human/provider effect this same call means the effect
                    // never actually runs -- reporting `RetainedEffect` here
                    // would audit something that did not happen. The
                    // enclosing mutation still gets its own ordinary audit.
                    Ok(None)
                } else {
                    apply_placement_effect_in_tx(transaction, item, existing.verdict, decided_at)
                        .await?;
                    Ok(Some(TriageOutcome::RetainedEffect(existing)))
                }
            }
            _ => Ok(None),
        };
    };
    let outcome = evaluate_builtin_v1(item);
    let decision = record_triage_decision_in_tx(
        transaction,
        &item.id,
        outcome.verdict,
        outcome.reason_code,
        outcome.reason_detail.as_deref(),
        BUILTIN_V1_EVALUATOR_IDENTITY,
        BUILTIN_V1_EVALUATOR_VERSION,
        &fingerprint,
        cause,
        decided_at,
    )
    .await?;
    let manually_placed = item
        .lane_origin
        .as_ref()
        .is_some_and(TaskBoardLaneOrigin::is_manual);
    if !manually_placed && !suppress_placement {
        apply_placement_effect_in_tx(transaction, item, outcome.verdict, decided_at).await?;
    }
    Ok(Some(TriageOutcome::Decided(decision)))
}

/// An evaluator upgrade takes precedence over a simultaneous fingerprint
/// change: if both differ from the existing decision at once, the cause
/// reported is `ActiveEvaluatorChanged`, not `FingerprintChanged`, since the
/// evaluator identity/version change is the more significant reason a new
/// decision is warranted.
fn triage_cause(
    existing: Option<&TaskBoardTriageDecision>,
    fingerprint: &str,
) -> Option<TriageCause> {
    match existing {
        None => Some(TriageCause::Initial),
        Some(existing)
            if existing.evaluator_identity != BUILTIN_V1_EVALUATOR_IDENTITY
                || existing.evaluator_version != BUILTIN_V1_EVALUATOR_VERSION =>
        {
            Some(TriageCause::ActiveEvaluatorChanged)
        }
        Some(existing) if existing.evidence_fingerprint != fingerprint => {
            Some(TriageCause::FingerprintChanged)
        }
        Some(_) => None,
    }
}

async fn apply_placement_effect_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    verdict: TriageVerdict,
    decided_at: &str,
) -> Result<(), CliError> {
    match verdict {
        TriageVerdict::Todo => promote_to_todo_in_tx(transaction, item, decided_at).await,
        TriageVerdict::Undecided => {
            demote_automatic_todo_to_backlog(item);
            Ok(())
        }
    }
}

/// Promotes an eligible Backlog item to Todo, or re-ranks an item that is
/// already Todo (its evidence changed for some other reason, such as a
/// priority edit, while the verdict itself stayed Todo). The caller has
/// already confirmed the item is not manually placed and placement is not
/// suppressed for this mutation, so any Todo status reaching here is either
/// this evaluator's own prior placement or a plain default from creation.
async fn promote_to_todo_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    decided_at: &str,
) -> Result<(), CliError> {
    let status = item.status.canonical_persisted_status();
    if status != TaskBoardStatus::Backlog && status != TaskBoardStatus::Todo {
        return Ok(());
    }
    let position = compute_builtin_v1_todo_position_in_tx(transaction, item).await?;
    item.status = TaskBoardStatus::Todo;
    item.lane_position = Some(position);
    item.lane_origin = Some(TaskBoardLaneOrigin::Automatic {
        producer: BUILTIN_V1_EVALUATOR_IDENTITY.to_string(),
    });
    item.lane_set_at = Some(decided_at.to_string());
    Ok(())
}

/// Undecided always means Backlog for a non-manual, non-suppressed item,
/// whether it is arriving fresh (created Todo by default, never placed) or
/// falling back from a prior `BuiltInV1` Todo placement.
fn demote_automatic_todo_to_backlog(item: &mut TaskBoardItem) {
    if item.status.canonical_persisted_status() != TaskBoardStatus::Todo {
        return;
    }
    item.status = TaskBoardStatus::Backlog;
    item.lane_position = None;
    item.lane_origin = None;
    item.lane_set_at = None;
}

/// A direct human status move on the general item-update endpoint is never
/// itself a durable `Manual` lane anchor -- that explicit override control
/// belongs to #333 -- but it still invalidates whatever `Automatic`
/// placement `BuiltInV1` previously recorded. Clearing that stale
/// provenance here (rather than suppressing placement while leaving the old
/// `Automatic` tag attached) keeps the item eligible for a fresh automatic
/// placement on its next eligible evaluation and stops the audit trail from
/// misattributing a human-chosen status to the evaluator. An existing
/// `Manual` anchor from #435 is left untouched.
pub(super) fn clear_stale_automatic_placement_on_human_status_move(
    before_status: TaskBoardStatus,
    item: &mut TaskBoardItem,
) {
    if before_status == item.status.canonical_persisted_status() {
        return;
    }
    let is_stale_automatic = item
        .lane_origin
        .as_ref()
        .is_some_and(|origin| !origin.is_manual());
    if is_stale_automatic {
        item.lane_position = None;
        item.lane_origin = None;
        item.lane_set_at = None;
    }
}

/// Whether `item`'s current, persisted placement already reflects `verdict`
/// exactly, i.e. whether `apply_placement_effect_in_tx` would be a genuine
/// no-op for this verdict. Used to detect a real desync (status reset by
/// something other than triage, such as a provider-exclusion restore)
/// without re-triggering placement on every otherwise-unrelated, truly
/// unchanged evaluation. A manually anchored item is never "congruent" here
/// on its own terms -- the caller checks `lane_origin` separately and treats
/// a manual anchor as suppressed, never as a placement to reapply.
fn placement_matches_verdict(item: &TaskBoardItem, verdict: TriageVerdict) -> bool {
    match verdict {
        TriageVerdict::Todo => {
            item.status.canonical_persisted_status() == TaskBoardStatus::Todo
                && item.lane_position.is_some()
                && item.lane_set_at.is_some()
                && matches!(
                    &item.lane_origin,
                    Some(TaskBoardLaneOrigin::Automatic { producer })
                        if producer == BUILTIN_V1_EVALUATOR_IDENTITY
                )
        }
        TriageVerdict::Undecided => {
            item.status.canonical_persisted_status() == TaskBoardStatus::Backlog
                && item.lane_position.is_none()
                && item.lane_origin.is_none()
                && item.lane_set_at.is_none()
        }
    }
}

/// Rank `candidate` among the other live Todo-lane items using the same
/// comparator the read path uses for default ordering (priority descending,
/// then `created_at`, then id), then return the zero-based slot that ranking
/// implies. `sort_task_board_items` treats any item carrying a stored
/// `lane_position` as a fixed anchor rather than re-ranking it, so a
/// non-manual sibling's stale prior slot must be cleared first -- otherwise
/// a newly arriving high-priority item can never displace it. Manual anchors
/// are left untouched so they still occupy a fixed absolute slot in this
/// ranking, matching what the caller's automatic lane-transition write
/// expects. The caller passes the resulting slot to that write, which
/// performs the actual collision-safe resequencing around manual anchors.
async fn compute_builtin_v1_todo_position_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    candidate: &TaskBoardItem,
) -> Result<u32, CliError> {
    let entries = load_lane_entries_in_tx(transaction, None, Some(TaskBoardStatus::Todo)).await?;
    let mut siblings = entries
        .into_iter()
        .map(|entry| entry.item)
        .filter(|sibling| sibling.id != candidate.id)
        .collect::<Vec<_>>();
    for sibling in &mut siblings {
        if !sibling
            .lane_origin
            .as_ref()
            .is_some_and(TaskBoardLaneOrigin::is_manual)
        {
            sibling.lane_position = None;
        }
    }
    let mut candidate_for_sort = candidate.clone();
    candidate_for_sort.status = TaskBoardStatus::Todo;
    candidate_for_sort.lane_position = None;
    siblings.push(candidate_for_sort);
    sort_task_board_items(&mut siblings);
    siblings
        .iter()
        .position(|sibling| sibling.id == candidate.id)
        .and_then(|position| u32::try_from(position).ok())
        .ok_or_else(|| db_error("compute builtin v1 todo position"))
}

#[cfg(test)]
#[path = "triage_apply_tests.rs"]
mod tests;
