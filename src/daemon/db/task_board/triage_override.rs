use sqlx::{Sqlite, Transaction, query, query_as};

use super::ITEMS_CHANGE_SCOPE;
use super::dispatch_intents::helpers::has_active_dispatch_reservation_in_tx;
use super::items::{
    apply_task_board_item_status_transition_in_tx, bump_change_in_tx,
    load_item_with_triage_override_in_tx,
};
use super::lane_order::{
    LaneTransitionKind, TaskBoardLaneShift, replace_with_lane_transition_in_tx,
};
use super::rows::ItemRow;
use super::triage_apply::{
    EnsuredTriageDecision, apply_override_placement_effect_in_tx,
    ensure_current_triage_decision_in_tx, triage_eligible,
};
use super::triage_decisions::current_triage_decision_in_tx;
use super::triage_override_audit::{
    record_triage_override_cleared_audit_in_tx, record_triage_override_set_audit_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::errors::CliErrorKind;
use crate::task_board::{
    BUILTIN_V1_EVALUATOR_IDENTITY, OVERRIDE_PLACEMENT_PRODUCER, TaskBoardItem,
    TaskBoardTriageEffectiveOutcome, TaskBoardTriageOverride, TriageVerdict,
    effective_triage_outcome, is_canonical_decided_at, is_canonical_override_actor,
    is_canonical_override_reason,
};

#[derive(sqlx::FromRow)]
struct TriageOverrideRow {
    verdict: Option<String>,
    actor: Option<String>,
    reason: Option<String>,
    set_at: Option<String>,
}

/// Load the active triage override (if any) for one item. Re-validates every
/// canonical-shape field on read since the SQL CHECK constraints alone do not
/// rule out a non-canonical actor/reason/timestamp payload written by
/// anything other than [`write_triage_override_in_tx`].
pub(super) async fn current_triage_override_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<Option<TaskBoardTriageOverride>, CliError> {
    let row = query_as::<_, TriageOverrideRow>(
        "SELECT triage_override_verdict AS verdict, triage_override_actor AS actor,
                triage_override_reason AS reason, triage_override_set_at AS set_at
         FROM task_board_items WHERE item_id = ?1",
    )
    .bind(item_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "load task board triage override '{item_id}': {error}"
        ))
    })?;
    match row {
        Some(row) => override_from_row(row),
        None => Ok(None),
    }
}

fn override_from_row(row: TriageOverrideRow) -> Result<Option<TaskBoardTriageOverride>, CliError> {
    override_from_parts(row.verdict, row.actor, row.reason, row.set_at)
}

/// Decode the active triage override (if any) from a row already fetched by
/// [`super::items::load_item_with_triage_override_in_tx`], so a caller that
/// just loaded the item never re-queries this table for the same row.
pub(super) fn triage_override_from_item_row(
    row: &ItemRow,
) -> Result<Option<TaskBoardTriageOverride>, CliError> {
    override_from_parts(
        row.triage_override_verdict.clone(),
        row.triage_override_actor.clone(),
        row.triage_override_reason.clone(),
        row.triage_override_set_at.clone(),
    )
}

/// `verdict`/`actor`/`set_at` are all-or-nothing; `reason` may be absent
/// either way. Re-validates independently of the SQL `CHECK` constraints --
/// a corrupt partial row must fail closed, not read as "no override".
fn override_from_parts(
    verdict: Option<String>,
    actor: Option<String>,
    reason: Option<String>,
    set_at: Option<String>,
) -> Result<Option<TaskBoardTriageOverride>, CliError> {
    let (verdict, actor, set_at) = match (verdict, actor, set_at) {
        (None, None, None) => {
            if reason.is_some() {
                return Err(db_error(
                    "stored triage override has a reason with no active verdict",
                ));
            }
            return Ok(None);
        }
        (Some(verdict), Some(actor), Some(set_at)) => (verdict, actor, set_at),
        _ => {
            return Err(db_error(
                "stored triage override verdict/actor/set_at tuple is partially populated",
            ));
        }
    };
    if !is_canonical_override_actor(&actor) {
        return Err(db_error("stored triage override actor is not canonical"));
    }
    if let Some(reason) = reason.as_deref()
        && !is_canonical_override_reason(reason)
    {
        return Err(db_error("stored triage override reason is not canonical"));
    }
    if !is_canonical_decided_at(&set_at) {
        return Err(db_error("stored triage override set_at is not canonical"));
    }
    Ok(Some(TaskBoardTriageOverride {
        verdict: parse_override_verdict(&verdict)?,
        actor,
        reason,
        set_at,
    }))
}

const fn override_verdict_wire(verdict: TriageVerdict) -> &'static str {
    match verdict {
        TriageVerdict::Todo => "todo",
        TriageVerdict::Undecided => "undecided",
    }
}

fn parse_override_verdict(value: &str) -> Result<TriageVerdict, CliError> {
    match value {
        "todo" => Ok(TriageVerdict::Todo),
        "undecided" => Ok(TriageVerdict::Undecided),
        other => Err(db_error(format!(
            "unknown stored triage override verdict '{other}'"
        ))),
    }
}

async fn write_triage_override_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    verdict: TriageVerdict,
    actor: &str,
    reason: Option<&str>,
    set_at: &str,
) -> Result<(), CliError> {
    query(
        "UPDATE task_board_items SET
             triage_override_verdict = ?2, triage_override_actor = ?3,
             triage_override_reason = ?4, triage_override_set_at = ?5
         WHERE item_id = ?1",
    )
    .bind(item_id)
    .bind(override_verdict_wire(verdict))
    .bind(actor)
    .bind(reason)
    .bind(set_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "write task board triage override '{item_id}': {error}"
        ))
    })?;
    Ok(())
}

async fn clear_triage_override_row_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<(), CliError> {
    query(
        "UPDATE task_board_items SET
             triage_override_verdict = NULL, triage_override_actor = NULL,
             triage_override_reason = NULL, triage_override_set_at = NULL
         WHERE item_id = ?1",
    )
    .bind(item_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "clear task board triage override '{item_id}': {error}"
        ))
    })?;
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardTriageOverrideSetInput {
    pub(crate) item_id: String,
    pub(crate) verdict: TriageVerdict,
    pub(crate) actor: String,
    pub(crate) reason: Option<String>,
    pub(crate) expected_item_revision: i64,
    pub(crate) expected_items_change_seq: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardTriageOverrideClearInput {
    pub(crate) item_id: String,
    pub(crate) actor: String,
    pub(crate) expected_item_revision: i64,
    pub(crate) expected_items_change_seq: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct TaskBoardTriageOverrideMutationResult {
    pub(crate) item: TaskBoardItem,
    pub(crate) item_revision: i64,
    pub(crate) items_change_seq: i64,
    pub(crate) shifted: Vec<TaskBoardLaneShift>,
    pub(crate) override_: Option<TaskBoardTriageOverride>,
    pub(crate) effective: Option<TaskBoardTriageEffectiveOutcome>,
}

impl AsyncDaemonDb {
    /// Set (or replace) a durable triage override under one item-revision
    /// and item-list sequence CAS. Always authoritative for lane outcome,
    /// even over a manual anchor -- a manually anchored item still moves
    /// lanes, carrying its slot/actor/`lane_set_at` with it.
    pub(crate) async fn set_task_board_triage_override(
        &self,
        input: TaskBoardTriageOverrideSetInput,
    ) -> Result<TaskBoardTriageOverrideMutationResult, CliError> {
        validate_override_actor_and_reason(&input.actor, input.reason.as_deref())?;
        let mut transaction = self
            .begin_immediate_transaction("task board triage override set")
            .await?;
        ensure_expected_sequence_in_tx(&mut transaction, input.expected_items_change_seq).await?;
        let (mut item, revision, before_override) =
            load_item_with_triage_override_in_tx(&mut transaction, &input.item_id)
                .await?
                .ok_or_else(|| {
                    db_error(format!("task-board item '{}' not found", input.item_id))
                })?;
        ensure_expected_revision(&item.id, revision, input.expected_item_revision)?;
        if item.deleted_at.is_some() {
            return Err(CliErrorKind::invalid_transition(
                "cannot set a triage override for a deleted task-board item",
            )
            .into());
        }
        if !triage_eligible(&item)
            || has_active_dispatch_reservation_in_tx(&mut transaction, &item.id).await?
        {
            return Err(CliErrorKind::invalid_transition(
                "task-board item is not eligible for a triage override",
            )
            .into());
        }
        let before = item.clone();
        let before_decision = current_triage_decision_in_tx(&mut transaction, &item.id).await?;
        let before_effective =
            effective_triage_outcome(before_override.as_ref(), before_decision.as_ref());
        let now = utc_now();
        let transition = apply_override_placement_effect_in_tx(
            &mut transaction,
            &mut item,
            input.verdict,
            &now,
            OVERRIDE_PLACEMENT_PRODUCER,
            true,
        )
        .await?;
        apply_task_board_item_status_transition_in_tx(&mut transaction, &item).await?;
        let write = replace_with_lane_transition_in_tx(
            &mut transaction,
            before.clone(),
            revision,
            item,
            transition,
        )
        .await?;
        write_triage_override_in_tx(
            &mut transaction,
            &write.item.id,
            input.verdict,
            &input.actor,
            input.reason.as_deref(),
            &now,
        )
        .await?;
        let override_ = TaskBoardTriageOverride {
            verdict: input.verdict,
            actor: input.actor.clone(),
            reason: input.reason.clone(),
            set_at: now,
        };
        let after_effective = effective_triage_outcome(Some(&override_), before_decision.as_ref());
        let items_change_seq = bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        record_triage_override_set_audit_in_tx(
            &mut transaction,
            &before,
            before_effective,
            &override_,
            after_effective,
            &write,
            items_change_seq,
            input.expected_item_revision,
            input.expected_items_change_seq,
        )
        .await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task-board triage override set: {error}")))?;
        Ok(TaskBoardTriageOverrideMutationResult {
            item: write.item,
            item_revision: write.item_revision,
            items_change_seq,
            shifted: write.shifted,
            override_: Some(override_),
            effective: after_effective,
        })
    }

    /// Clear a durable triage override under one item-revision and
    /// item-list sequence CAS, first refreshing stale automatic evidence
    /// when needed and then reconciling that decision's placement. A manual
    /// anchor still reconciles, keeping its slot/actor/`lane_set_at`.
    pub(crate) async fn clear_task_board_triage_override(
        &self,
        input: TaskBoardTriageOverrideClearInput,
    ) -> Result<TaskBoardTriageOverrideMutationResult, CliError> {
        validate_override_actor_and_reason(&input.actor, None)?;
        let mut transaction = self
            .begin_immediate_transaction("task board triage override clear")
            .await?;
        ensure_expected_sequence_in_tx(&mut transaction, input.expected_items_change_seq).await?;
        let (mut item, revision, existing_override) =
            load_item_with_triage_override_in_tx(&mut transaction, &input.item_id)
                .await?
                .ok_or_else(|| {
                    db_error(format!("task-board item '{}' not found", input.item_id))
                })?;
        ensure_expected_revision(&item.id, revision, input.expected_item_revision)?;
        if item.deleted_at.is_some() {
            return Err(CliErrorKind::invalid_transition(
                "cannot clear a triage override for a deleted task-board item",
            )
            .into());
        }
        let Some(existing_override) = existing_override else {
            return Err(CliErrorKind::invalid_transition(
                "task-board item has no active triage override to clear",
            )
            .into());
        };
        if has_active_dispatch_reservation_in_tx(&mut transaction, &item.id).await? {
            return Err(CliErrorKind::invalid_transition(
                "cannot clear a triage override while a dispatch reservation is active",
            )
            .into());
        }
        let before = item.clone();
        let now = utc_now();
        let reconciliation =
            reconcile_cleared_override_in_tx(&mut transaction, &mut item, &existing_override, &now)
                .await?;
        apply_task_board_item_status_transition_in_tx(&mut transaction, &item).await?;
        let write = replace_with_lane_transition_in_tx(
            &mut transaction,
            before.clone(),
            revision,
            item,
            reconciliation.transition,
        )
        .await?;
        clear_triage_override_row_in_tx(&mut transaction, &write.item.id).await?;
        let items_change_seq = bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        record_triage_override_cleared_audit_in_tx(
            &mut transaction,
            &before,
            &existing_override,
            reconciliation.before_effective,
            reconciliation.after_effective,
            reconciliation.decision.as_ref(),
            reconciliation.reconciled,
            &write,
            items_change_seq,
            input.expected_item_revision,
            input.expected_items_change_seq,
            &input.actor,
        )
        .await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit task-board triage override clear: {error}"))
        })?;
        Ok(TaskBoardTriageOverrideMutationResult {
            item: write.item,
            item_revision: write.item_revision,
            items_change_seq,
            shifted: write.shifted,
            override_: None,
            effective: reconciliation.after_effective,
        })
    }
}

struct ClearReconciliation {
    decision: Option<EnsuredTriageDecision>,
    before_effective: Option<TaskBoardTriageEffectiveOutcome>,
    after_effective: Option<TaskBoardTriageEffectiveOutcome>,
    reconciled: bool,
    transition: LaneTransitionKind,
}

/// Reveal the current automatic outcome, never a generation that predates
/// the item's latest evaluator or evidence. Ineligible items do not
/// re-evaluate, but keep their retained decision so the clear response and
/// the next read agree.
async fn reconcile_cleared_override_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    existing_override: &TaskBoardTriageOverride,
    now: &str,
) -> Result<ClearReconciliation, CliError> {
    let eligible = triage_eligible(item);
    let decision = if eligible {
        ensure_current_triage_decision_in_tx(transaction, item, now).await?
    } else {
        current_triage_decision_in_tx(transaction, &item.id)
            .await?
            .map(EnsuredTriageDecision::Existing)
    };
    let automatic = decision.as_ref().map(EnsuredTriageDecision::decision);
    let before_effective = effective_triage_outcome(Some(existing_override), automatic);
    let reconciled = eligible && decision.is_some();
    let transition = if let (true, Some(automatic)) = (eligible, automatic) {
        apply_override_placement_effect_in_tx(
            transaction,
            item,
            automatic.verdict,
            now,
            BUILTIN_V1_EVALUATOR_IDENTITY,
            false,
        )
        .await?
    } else {
        LaneTransitionKind::Automatic
    };
    let after_effective = effective_triage_outcome(None, automatic);
    Ok(ClearReconciliation {
        decision,
        before_effective,
        after_effective,
        reconciled,
        transition,
    })
}

fn validate_override_actor_and_reason(actor: &str, reason: Option<&str>) -> Result<(), CliError> {
    if !is_canonical_override_actor(actor) {
        return Err(db_error("triage override actor is not canonical"));
    }
    if let Some(reason) = reason
        && !is_canonical_override_reason(reason)
    {
        return Err(db_error("triage override reason is not canonical"));
    }
    Ok(())
}

async fn ensure_expected_sequence_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: i64,
) -> Result<(), CliError> {
    let actual = sqlx::query_scalar::<_, i64>(
        "SELECT COALESCE(change_seq, 0) FROM change_tracking WHERE scope = ?1",
    )
    .bind(ITEMS_CHANGE_SCOPE)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("read task-board triage override sequence: {error}")))?
    .unwrap_or(0);
    if actual == expected {
        return Ok(());
    }
    Err(CliErrorKind::concurrent_modification(format!(
        "task-board item sequence changed from {expected} to {actual}"
    ))
    .into())
}

fn ensure_expected_revision(item_id: &str, actual: i64, expected: i64) -> Result<(), CliError> {
    if actual == expected {
        return Ok(());
    }
    Err(CliErrorKind::concurrent_modification(format!(
        "task-board item '{item_id}' revision changed from {expected} to {actual}"
    ))
    .into())
}

#[cfg(test)]
#[path = "triage_override_parts_decode_tests.rs"]
mod parts_decode_tests;

#[cfg(test)]
#[path = "triage_override_db_tests.rs"]
mod tests;
