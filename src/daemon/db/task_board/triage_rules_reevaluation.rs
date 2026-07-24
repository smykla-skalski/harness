use sqlx::{Sqlite, Transaction};

use super::ITEMS_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::lane_order::{LaneTransitionKind, record_lane_transition_audit_in_tx, replace_with_lane_transition_in_tx};
use super::triage_apply::{
    apply_override_placement_effect_in_tx, apply_placement_effect_in_tx, placement_matches_verdict,
    triage_eligible,
};
use super::triage_apply_rules::ActiveRuleSetEvaluator;
use super::triage_cause::triage_cause;
use super::triage_decisions::record_triage_decision_in_tx;
use super::triage_rules_bulk_load::{
    TriageBulkEntry, load_active_dispatch_reservation_item_ids_in_tx, load_triage_bulk_entries_in_tx,
};
use crate::daemon::db::CliError;
use crate::task_board::{
    BUILTIN_V1_EVALUATOR_IDENTITY, BUILTIN_V1_EVALUATOR_VERSION, OVERRIDE_PLACEMENT_PRODUCER,
    TaskBoardLaneOrigin, TriagePriorityAction, TriageReasonCode, TriageRuleMatch, evaluate_builtin_v1,
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
    // A cause of `None` means the same evaluator already decided this exact
    // evidence -- recording another generation here would spam decision
    // history on every no-op reevaluation (for example, repeatedly
    // deactivating when nothing is active). Still reconcile placement in
    // that case, but only if it is genuinely desynced from what the
    // unchanged decision implies, mirroring the single-item choke point's
    // retained-effect check.
    let cause = triage_cause(
        current_decision.as_ref(),
        &fingerprint,
        decided.evaluator_identity,
        decided.evaluator_version,
    );
    if let Some(cause) = cause {
        record_triage_decision_in_tx(
            transaction,
            &item.id,
            decided.verdict,
            decided.reason_code,
            decided.reason_detail.as_deref(),
            decided.evaluator_identity,
            decided.evaluator_version,
            &fingerprint,
            cause,
            now,
        )
        .await?;
        if let TriagePriorityAction::SetTo { priority } = decided.priority_action {
            item.priority = priority;
        }
    }
    let manually_placed = item
        .lane_origin
        .as_ref()
        .is_some_and(TaskBoardLaneOrigin::is_manual);
    if let Some(existing_override) = &override_ {
        apply_override_placement_effect_in_tx(
            transaction,
            &mut item,
            existing_override.verdict,
            now,
            OVERRIDE_PLACEMENT_PRODUCER,
            true,
        )
        .await?;
    } else if !manually_placed {
        // A fresh decision (`cause.is_some()`) always places under this
        // touch's active evaluator. A retained decision (`cause` is `None`,
        // for instance a pinned `AGENT_V1` verdict this reevaluation must
        // not disturb) places under ITS OWN evaluator identity and verdict,
        // never the active evaluator's hypothetical, unrecorded outcome --
        // otherwise a rule-set activation would churn an agent-placed Todo
        // back to Backlog on every activation without ever recording why.
        let (retained_verdict, retained_producer) = match &cause {
            Some(_) => (decided.verdict, decided.evaluator_identity),
            None => match current_decision.as_ref() {
                Some(existing) => (existing.verdict, existing.evaluator_identity.as_str()),
                None => (decided.verdict, decided.evaluator_identity),
            },
        };
        if !placement_matches_verdict(&item, retained_verdict, retained_producer) {
            apply_placement_effect_in_tx(transaction, &mut item, retained_verdict, now, retained_producer)
                .await?;
        }
    }
    let changed = item.status != before.status
        || item.lane_position != before.lane_position
        || item.lane_origin != before.lane_origin
        || item.lane_set_at != before.lane_set_at
        || item.priority != before.priority;
    if !changed {
        return Ok(());
    }
    item.updated_at = now.to_string();
    let write =
        replace_with_lane_transition_in_tx(transaction, before, revision, item, LaneTransitionKind::Automatic)
            .await?;
    let items_change_seq = bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
    record_lane_transition_audit_in_tx(transaction, &write, items_change_seq).await?;
    Ok(())
}

struct Decided<'a> {
    verdict: crate::task_board::TriageVerdict,
    reason_code: TriageReasonCode,
    reason_detail: Option<String>,
    evaluator_identity: &'a str,
    evaluator_version: u32,
    priority_action: TriagePriorityAction,
}

fn decide<'a>(
    active: Option<&'a ActiveRuleSetEvaluator>,
    item: &crate::task_board::TaskBoardItem,
) -> Decided<'a> {
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
            evaluator_identity: crate::task_board::RUNTIME_RULES_EVALUATOR_IDENTITY,
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
