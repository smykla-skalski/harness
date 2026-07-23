use sqlx::{Sqlite, Transaction};

use super::dispatch_intents::helpers::has_active_dispatch_reservation_in_tx;
use super::lane_order::{LaneTransitionKind, load_lane_entries_in_tx};
use super::triage_decisions::{current_triage_decision_in_tx, record_triage_decision_in_tx};
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    BUILTIN_V1_EVALUATOR_IDENTITY, BUILTIN_V1_EVALUATOR_VERSION, OVERRIDE_PLACEMENT_PRODUCER,
    TaskBoardItem, TaskBoardLaneOrigin, TaskBoardStatus, TaskBoardTriageDecision,
    TaskBoardTriageOverride, TriageCause, TriageVerdict, evaluate_builtin_v1, evidence_fingerprint,
    sort_task_board_items, suppress_placement_for_override,
};

/// Only dispatchable, live, unlinked, pre-dispatch items are `BuiltInV1`'s
/// business. Everything else (umbrellas, tombstones, already-dispatched
/// items, and items past Backlog/Todo) gets no decision at all.
pub(super) fn triage_eligible(item: &TaskBoardItem) -> bool {
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

#[derive(Debug)]
pub(super) enum EnsuredTriageDecision {
    Decided(TaskBoardTriageDecision),
    Existing(TaskBoardTriageDecision),
}

impl EnsuredTriageDecision {
    pub(super) const fn decision(&self) -> &TaskBoardTriageDecision {
        match self {
            Self::Decided(decision) | Self::Existing(decision) => decision,
        }
    }

    pub(super) const fn outcome_kind(&self) -> &'static str {
        match self {
            Self::Decided(_) => "decided",
            Self::Existing(_) => "existing",
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
/// ineligible or the decision is unchanged (idempotent). `existing_override`
/// is the item's already-loaded active override (or `None`) -- the caller
/// supplies it from whatever query already fetched this same row, rather
/// than this function issuing a second one for the same four columns.
pub(super) async fn apply_builtin_v1_triage_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    decided_at: &str,
    suppress_placement: bool,
    existing_override: Option<&TaskBoardTriageOverride>,
) -> Result<Option<TriageOutcome>, CliError> {
    if !triage_eligible(item)
        || has_active_dispatch_reservation_in_tx(transaction, &item.id).await?
    {
        return Ok(None);
    }
    // An active override always wins the placement effect, but evaluation
    // itself keeps running underneath it so a fresh decision generation and
    // evidence fingerprint are ready the moment the override is cleared.
    let override_active = suppress_placement_for_override(existing_override);
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
                if manually_placed || suppress_placement || override_active {
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
    if !manually_placed && !suppress_placement && !override_active {
        apply_placement_effect_in_tx(transaction, item, outcome.verdict, decided_at).await?;
    }
    Ok(Some(TriageOutcome::Decided(decision)))
}

/// Ensure the item's decision reflects the current evaluator and evidence,
/// recording a fresh generation when either changed since the existing
/// decision (or there is none yet). Unlike
/// [`apply_builtin_v1_triage_in_tx`], this never touches placement -- a
/// caller revealing what the automatic evaluator currently says (a triage
/// override clear, for one) calls this first so it never reconciles against
/// a decision that predates the item's latest evaluator/evidence, then
/// applies whatever placement effect it needs against the verdict this
/// returns.
pub(super) async fn ensure_current_triage_decision_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
    decided_at: &str,
) -> Result<Option<EnsuredTriageDecision>, CliError> {
    if !triage_eligible(item) {
        return Ok(None);
    }
    let fingerprint = evidence_fingerprint(item);
    let existing = current_triage_decision_in_tx(transaction, &item.id).await?;
    let Some(cause) = triage_cause(existing.as_ref(), &fingerprint) else {
        return Ok(existing.map(EnsuredTriageDecision::Existing));
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
    Ok(Some(EnsuredTriageDecision::Decided(decision)))
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

pub(super) async fn apply_placement_effect_in_tx(
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

/// Apply `verdict`'s placement effect for a set/reassert or clear. An
/// override always wins lane outcome, even over a manual anchor, but a
/// manual anchor's slot/actor/`lane_set_at` travel with it rather than
/// being overwritten. `producer` is the resulting provenance for a
/// non-manual item (`OVERRIDE_PLACEMENT_PRODUCER` for set/reassert,
/// `BUILTIN_V1_EVALUATOR_IDENTITY` for clear). `preserve_any_automatic_producer`
/// preserves an already-congruent slot's existing producer (true for
/// set/reassert) versus requiring an exact producer match to count as
/// congruent (false for clear, so a cleared override never leaves a slot
/// still claiming it).
pub(super) async fn apply_override_placement_effect_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    verdict: TriageVerdict,
    decided_at: &str,
    producer: &str,
    preserve_any_automatic_producer: bool,
) -> Result<LaneTransitionKind, CliError> {
    let manually_placed = item
        .lane_origin
        .as_ref()
        .is_some_and(TaskBoardLaneOrigin::is_manual);
    if manually_placed {
        item.status = override_implied_status(verdict);
        return Ok(LaneTransitionKind::Generic);
    }
    match verdict {
        TriageVerdict::Todo => {
            promote_to_todo_with_producer_in_tx(
                transaction,
                item,
                decided_at,
                producer,
                preserve_any_automatic_producer,
            )
            .await?;
        }
        TriageVerdict::Undecided => demote_automatic_todo_to_backlog(item),
    }
    Ok(LaneTransitionKind::Automatic)
}

/// The single lane a triage verdict implies, independent of manual
/// provenance or evaluator producer -- the one seam every override-outcome
/// enforcement point (set/clear, a conflicting human write, a
/// provider-reconcile reassertion) compares an item's current status
/// against.
pub(super) const fn override_implied_status(verdict: TriageVerdict) -> TaskBoardStatus {
    match verdict {
        TriageVerdict::Todo => TaskBoardStatus::Todo,
        TriageVerdict::Undecided => TaskBoardStatus::Backlog,
    }
}

/// Always reasserts an active override's placement on a `ProviderReconcile`
/// write, not only when status disagrees -- automatic re-ranking is
/// suppressed while an override is active, so a non-manual Todo override's
/// rank would otherwise freeze forever as sibling priorities change. Manual
/// rank is untouched either way. Skips reasserting while a dispatch
/// reservation is active, mirroring `apply_builtin_v1_triage_in_tx`, so a
/// reservation in flight sees a stable snapshot. Returns `None` when
/// reasserting was a genuine no-op (placement tuple unchanged), `Some`
/// otherwise.
pub(super) async fn reapply_active_override_outcome_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    existing_override: Option<&TaskBoardTriageOverride>,
    decided_at: &str,
) -> Result<Option<LaneTransitionKind>, CliError> {
    let Some(existing_override) = existing_override else {
        return Ok(None);
    };
    if !triage_eligible(item)
        || has_active_dispatch_reservation_in_tx(transaction, &item.id).await?
    {
        return Ok(None);
    }
    let before = item.clone();
    let transition = apply_override_placement_effect_in_tx(
        transaction,
        item,
        existing_override.verdict,
        decided_at,
        OVERRIDE_PLACEMENT_PRODUCER,
        true,
    )
    .await?;
    let placement_changed = item.status != before.status
        || item.lane_position != before.lane_position
        || item.lane_origin != before.lane_origin
        || item.lane_set_at != before.lane_set_at;
    Ok(placement_changed.then_some(transition))
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

/// Like [`promote_to_todo_in_tx`], but stamps `producer` instead of always
/// attributing the slot to `BuiltInV1`. Leaves an already-congruent slot
/// untouched rather than re-stamping it (see `preserve_any_automatic_producer`).
async fn promote_to_todo_with_producer_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    decided_at: &str,
    producer: &str,
    preserve_any_automatic_producer: bool,
) -> Result<(), CliError> {
    let status = item.status.canonical_persisted_status();
    if status != TaskBoardStatus::Backlog && status != TaskBoardStatus::Todo {
        return Ok(());
    }
    let position = compute_builtin_v1_todo_position_in_tx(transaction, item).await?;
    let already_congruent = status == TaskBoardStatus::Todo
        && item.lane_position == Some(position)
        && match &item.lane_origin {
            Some(TaskBoardLaneOrigin::Automatic { producer: existing }) => {
                preserve_any_automatic_producer || existing == producer
            }
            _ => false,
        };
    if already_congruent {
        return Ok(());
    }
    item.status = TaskBoardStatus::Todo;
    item.lane_position = Some(position);
    item.lane_origin = Some(TaskBoardLaneOrigin::Automatic {
        producer: producer.to_string(),
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
/// is a separate feature -- but it still invalidates whatever `Automatic`
/// placement `BuiltInV1` previously recorded. Clearing that stale
/// provenance here (rather than suppressing placement while leaving the old
/// `Automatic` tag attached) keeps the item eligible for a fresh automatic
/// placement on its next eligible evaluation and stops the audit trail from
/// misattributing a human-chosen status to the evaluator. An existing
/// `Manual` anchor is left untouched.
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
