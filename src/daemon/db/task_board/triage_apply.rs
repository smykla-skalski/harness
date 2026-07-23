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

fn is_builtin_v1_automatic(origin: &TaskBoardLaneOrigin) -> bool {
    matches!(origin, TaskBoardLaneOrigin::Automatic { producer } if producer == BUILTIN_V1_EVALUATOR_IDENTITY)
}

/// Evaluate and, where warranted, apply the `BuiltInV1` deterministic triage
/// check table against `item` in place, inside the caller's ongoing
/// transaction. Mutates `item.status`/`lane_position`/`lane_origin`/
/// `lane_set_at` for a Backlog-to-Todo promotion or an automatic-only
/// Todo-to-Backlog demotion; never touches a manually placed item's status or
/// placement, though its decision and history still refresh. Returns `None`
/// when the item is ineligible or the decision is unchanged (idempotent).
pub(super) async fn apply_builtin_v1_triage_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    decided_at: &str,
) -> Result<Option<TaskBoardTriageDecision>, CliError> {
    if !triage_eligible(item) {
        return Ok(None);
    }
    let fingerprint = evidence_fingerprint(item);
    let existing = current_triage_decision_in_tx(transaction, &item.id).await?;
    let Some(cause) = triage_cause(existing.as_ref(), &fingerprint) else {
        return Ok(None);
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
    if !manually_placed {
        apply_placement_effect_in_tx(transaction, item, outcome.verdict, decided_at).await?;
    }
    Ok(Some(decision))
}

fn triage_cause(
    existing: Option<&TaskBoardTriageDecision>,
    fingerprint: &str,
) -> Option<TriageCause> {
    match existing {
        None => Some(TriageCause::Initial),
        Some(existing) if existing.evidence_fingerprint != fingerprint => {
            Some(TriageCause::FingerprintChanged)
        }
        Some(existing)
            if existing.evaluator_identity != BUILTIN_V1_EVALUATOR_IDENTITY
                || existing.evaluator_version != BUILTIN_V1_EVALUATOR_VERSION =>
        {
            Some(TriageCause::ActiveEvaluatorChanged)
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

async fn promote_to_todo_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    decided_at: &str,
) -> Result<(), CliError> {
    if item.status.canonical_persisted_status() != TaskBoardStatus::Backlog {
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

fn demote_automatic_todo_to_backlog(item: &mut TaskBoardItem) {
    let was_automatic_todo = item.status.canonical_persisted_status() == TaskBoardStatus::Todo
        && item
            .lane_origin
            .as_ref()
            .is_some_and(is_builtin_v1_automatic);
    if !was_automatic_todo {
        return;
    }
    item.status = TaskBoardStatus::Backlog;
    item.lane_position = None;
    item.lane_origin = None;
    item.lane_set_at = None;
}

/// Rank `candidate` among the other live Todo-lane items using the same
/// comparator the read path uses for default ordering (priority descending,
/// then `created_at`, then id), then return the zero-based slot that ranking
/// implies. The caller passes this to the existing lane-transition write,
/// which performs the actual collision-safe shift.
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
    let mut candidate_for_sort = candidate.clone();
    candidate_for_sort.status = TaskBoardStatus::Todo;
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
