use sqlx::{Sqlite, Transaction};

use super::ITEMS_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::lane_order::{
    LaneTransitionKind, record_lane_transition_audit_in_tx, replace_with_lane_transition_in_tx,
};
use super::triage_apply::{
    apply_override_placement_effect_in_tx, apply_placement_effect_in_tx, placement_matches_verdict,
    triage_eligible,
};
use super::triage_apply_rules::ActiveRuleSetEvaluator;
use super::triage_cause::triage_cause;
use super::triage_decisions::record_triage_decision_in_tx;
use super::triage_rules_bulk_load::{
    CurrentDecisionInfo, TriageBulkEntry, load_active_dispatch_reservation_item_ids_in_tx,
    load_triage_bulk_entries_in_tx,
};
use crate::daemon::db::CliError;
use crate::task_board::{
    BUILTIN_V1_EVALUATOR_IDENTITY, BUILTIN_V1_EVALUATOR_VERSION, OVERRIDE_PLACEMENT_PRODUCER,
    RUNTIME_RULES_EVALUATOR_IDENTITY, TaskBoardItem, TaskBoardLaneOrigin, TaskBoardTriageOverride,
    TriagePriorityAction, TriageReasonCode, TriageRuleMatch, TriageVerdict, evaluate_builtin_v1,
    evaluate_triage_rule_set, evidence_fingerprint,
};

/// Bulk-reevaluate every triage-eligible item against whichever evaluator
/// activation just made current, inside the caller's activation
/// transaction. Loads the eligible item set and the active-reservation id
/// set with a fixed set of bulk queries (see [`load_triage_bulk_entries_in_tx`]
/// and [`load_active_dispatch_reservation_item_ids_in_tx`]) and never
/// re-reads an item individually; only items whose decision, placement, or
/// priority actually changes get an item-row write, so an activation that
/// resolves identically to the prior evaluator produces no observable
/// churn. Skips an item mid-dispatch-reservation entirely, mirroring the
/// ordinary single-item choke point.
pub(super) async fn reevaluate_all_triage_eligible_items_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    active: Option<&ActiveRuleSetEvaluator>,
    now: &str,
) -> Result<usize, CliError> {
    let entries = load_triage_bulk_entries_in_tx(transaction).await?;
    let reserved = load_active_dispatch_reservation_item_ids_in_tx(transaction).await?;
    let mut reevaluated = 0usize;
    for entry in entries {
        if !triage_eligible(&entry.item) {
            continue;
        }
        if reserved.contains(&entry.item.id) {
            continue;
        }
        reevaluate_one_item_in_tx(transaction, entry, active, now).await?;
        reevaluated += 1;
    }
    Ok(reevaluated)
}

async fn reevaluate_one_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    entry: TriageBulkEntry,
    active: Option<&ActiveRuleSetEvaluator>,
    now: &str,
) -> Result<(), CliError> {
    let TriageBulkEntry {
        mut item,
        revision,
        override_,
        current_decision,
    } = entry;
    let before = item.clone();
    let fingerprint = evidence_fingerprint(&item);
    let decided = decide(active, &item);
    let recorded = record_reevaluated_decision_in_tx(
        transaction,
        &mut item,
        current_decision.as_ref(),
        &decided,
        &fingerprint,
        now,
    )
    .await?;
    reconcile_reevaluated_placement_in_tx(
        transaction,
        &mut item,
        override_.as_ref(),
        current_decision.as_ref(),
        &decided,
        recorded,
        now,
    )
    .await?;
    if !placement_or_priority_changed(&before, &item) {
        return Ok(());
    }
    item.updated_at = now.to_string();
    write_reevaluated_item_in_tx(transaction, before, revision, item).await
}

/// Records a fresh decision generation and reports whether it did. A cause of
/// `None` means the same evaluator already decided this exact evidence --
/// recording another generation here would spam decision history on every
/// no-op reevaluation (for example, repeatedly deactivating when nothing is
/// active). The caller still reconciles placement in that case, but only if it
/// is genuinely desynced from what the unchanged decision implies, mirroring
/// the single-item choke point's retained-effect check.
async fn record_reevaluated_decision_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    current_decision: Option<&CurrentDecisionInfo>,
    decided: &Decided<'_>,
    fingerprint: &str,
    now: &str,
) -> Result<bool, CliError> {
    let Some(cause) = triage_cause(
        current_decision,
        fingerprint,
        decided.evaluator_identity,
        decided.evaluator_version,
    ) else {
        return Ok(false);
    };
    record_triage_decision_in_tx(
        transaction,
        &item.id,
        decided.verdict,
        decided.reason_code,
        decided.reason_detail.as_deref(),
        decided.evaluator_identity,
        decided.evaluator_version,
        fingerprint,
        cause,
        now,
    )
    .await?;
    if let TriagePriorityAction::SetTo { priority } = decided.priority_action {
        item.priority = priority;
    }
    Ok(true)
}

async fn reconcile_reevaluated_placement_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    override_: Option<&TaskBoardTriageOverride>,
    current_decision: Option<&CurrentDecisionInfo>,
    decided: &Decided<'_>,
    recorded: bool,
    now: &str,
) -> Result<(), CliError> {
    if let Some(existing_override) = override_ {
        return apply_override_placement_effect_in_tx(
            transaction,
            item,
            existing_override.verdict,
            now,
            OVERRIDE_PLACEMENT_PRODUCER,
            true,
        )
        .await
        .map(|_| ());
    }
    if item
        .lane_origin
        .as_ref()
        .is_some_and(TaskBoardLaneOrigin::is_manual)
    {
        return Ok(());
    }
    let (retained_verdict, retained_producer) =
        retained_placement(recorded, current_decision, decided);
    if placement_matches_verdict(item, retained_verdict, retained_producer) {
        return Ok(());
    }
    apply_placement_effect_in_tx(transaction, item, retained_verdict, now, retained_producer).await
}

/// A freshly recorded decision always places under this touch's active
/// evaluator. A retained decision (nothing recorded, for instance a pinned
/// `AGENT_V1` verdict this reevaluation must not disturb) places under ITS OWN
/// evaluator identity and verdict, never the active evaluator's hypothetical,
/// unrecorded outcome -- otherwise a rule-set activation would churn an
/// agent-placed Todo back to Inbox on every activation without ever
/// recording why.
fn retained_placement<'a>(
    recorded: bool,
    current_decision: Option<&'a CurrentDecisionInfo>,
    decided: &Decided<'a>,
) -> (TriageVerdict, &'a str) {
    if recorded {
        return (decided.verdict, decided.evaluator_identity);
    }
    match current_decision {
        Some(existing) => (existing.verdict, existing.evaluator_identity.as_str()),
        None => (decided.verdict, decided.evaluator_identity),
    }
}

fn placement_or_priority_changed(before: &TaskBoardItem, item: &TaskBoardItem) -> bool {
    item.status != before.status
        || item.lane_position != before.lane_position
        || item.lane_origin != before.lane_origin
        || item.lane_set_at != before.lane_set_at
        || item.priority != before.priority
}

async fn write_reevaluated_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    before: TaskBoardItem,
    revision: i64,
    item: TaskBoardItem,
) -> Result<(), CliError> {
    let write = replace_with_lane_transition_in_tx(
        transaction,
        before,
        revision,
        item,
        LaneTransitionKind::Automatic,
    )
    .await?;
    let items_change_seq = bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
    record_lane_transition_audit_in_tx(transaction, &write, items_change_seq).await
}

struct Decided<'a> {
    verdict: TriageVerdict,
    reason_code: TriageReasonCode,
    reason_detail: Option<String>,
    evaluator_identity: &'a str,
    evaluator_version: u32,
    priority_action: TriagePriorityAction,
}

fn decide<'a>(active: Option<&'a ActiveRuleSetEvaluator>, item: &TaskBoardItem) -> Decided<'a> {
    if let Some(active) = active {
        let evaluation = evaluate_triage_rule_set(&active.rules, item);
        let (reason_code, reason_detail) = match evaluation.matched {
            TriageRuleMatch::Rule(id) => (TriageReasonCode::RuleMatched, Some(id)),
            TriageRuleMatch::Default => (TriageReasonCode::RuleSetDefault, None),
        };
        Decided {
            verdict: evaluation.verdict,
            reason_code,
            reason_detail,
            evaluator_identity: RUNTIME_RULES_EVALUATOR_IDENTITY,
            evaluator_version: active.evaluator_version,
            priority_action: evaluation.priority_action,
        }
    } else {
        let outcome = evaluate_builtin_v1(item);
        Decided {
            verdict: outcome.verdict,
            reason_code: outcome.reason_code,
            reason_detail: outcome.reason_detail,
            evaluator_identity: BUILTIN_V1_EVALUATOR_IDENTITY,
            evaluator_version: BUILTIN_V1_EVALUATOR_VERSION,
            priority_action: TriagePriorityAction::Keep,
        }
    }
}

#[cfg(test)]
#[path = "triage_rules_reevaluation_tests.rs"]
mod tests;
