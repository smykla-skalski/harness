use sqlx::{Sqlite, Transaction, query_as};

use super::dispatch_intents::helpers::has_active_dispatch_reservation_in_tx;
use super::triage_apply::{
    EnsuredTriageDecision, TriageOutcome, apply_builtin_v1_triage_in_tx,
    apply_placement_effect_in_tx, ensure_current_triage_decision_in_tx, placement_matches_verdict,
    triage_eligible,
};
use super::triage_cause::triage_cause;
use super::triage_decisions::{current_triage_decision_in_tx, record_triage_decision_in_tx};
use super::triage_rules_store::decode_rule_set;
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    RUNTIME_RULES_EVALUATOR_IDENTITY, TaskBoardItem, TaskBoardLaneOrigin, TaskBoardTriageOverride,
    TriagePriorityAction, TriageReasonCode, TriageRuleMatch, TriageRuleSetV1, TriageVerdict,
    evaluate_triage_rule_set, evidence_fingerprint, suppress_placement_for_override,
};

/// The runtime-authored rule set activation currently made current, owned
/// so one load (per ingress call, or once per bulk reevaluation) can be
/// evaluated against many items without a second read.
pub(super) struct ActiveRuleSetEvaluator {
    pub(super) rules: TriageRuleSetV1,
    pub(super) evaluator_version: u32,
}

pub(super) async fn load_active_rule_set_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<Option<ActiveRuleSetEvaluator>, CliError> {
    let row = query_as::<_, (String, i64)>(
        "SELECT rules_json, revision FROM task_board_triage_rule_set_revisions WHERE status = 'active'",
    )
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("read active task board triage rule set: {error}")))?;
    let Some((rules_json, revision)) = row else {
        return Ok(None);
    };
    let rules = decode_rule_set(&rules_json)?;
    let evaluator_version = u32::try_from(revision)
        .map_err(|_| db_error("active task board triage rule set revision out of range"))?;
    Ok(Some(ActiveRuleSetEvaluator {
        rules,
        evaluator_version,
    }))
}

struct RuleDecision {
    verdict: TriageVerdict,
    reason_code: TriageReasonCode,
    reason_detail: Option<String>,
    priority_action: TriagePriorityAction,
}

fn evaluate_active_rules(active: &ActiveRuleSetEvaluator, item: &TaskBoardItem) -> RuleDecision {
    let evaluation = evaluate_triage_rule_set(&active.rules, item);
    let (reason_code, reason_detail) = match evaluation.matched {
        TriageRuleMatch::Rule(id) => (TriageReasonCode::RuleMatched, Some(id)),
        TriageRuleMatch::Default => (TriageReasonCode::RuleSetDefault, None),
    };
    RuleDecision {
        verdict: evaluation.verdict,
        reason_code,
        reason_detail,
        priority_action: evaluation.priority_action,
    }
}

/// Generalizes the ingress choke point over whichever evaluator is
/// currently active: delegates to [`apply_builtin_v1_triage_in_tx`]
/// verbatim -- the exact, unmodified `BuiltInV1` code path -- when no
/// custom rule set is active, so the default stays byte-compatible by
/// construction instead of by a parallel reimplementation kept in sync by
/// hand. Only branches into rule-based evaluation once an active rule set
/// is actually loaded; the branch mirrors `apply_builtin_v1_triage_in_tx`'s
/// shape exactly, substituting the rule-set evaluator's identity, version,
/// and outcome (including its `priority_action`) for `BuiltInV1`'s.
pub(super) async fn apply_active_triage_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
    decided_at: &str,
    suppress_placement: bool,
    existing_override: Option<&TaskBoardTriageOverride>,
) -> Result<Option<TriageOutcome>, CliError> {
    let Some(active) = load_active_rule_set_in_tx(transaction).await? else {
        return apply_builtin_v1_triage_in_tx(
            transaction,
            item,
            decided_at,
            suppress_placement,
            existing_override,
        )
        .await;
    };
    if !triage_eligible(item) || has_active_dispatch_reservation_in_tx(transaction, &item.id).await? {
        return Ok(None);
    }
    let override_active = suppress_placement_for_override(existing_override);
    let fingerprint = evidence_fingerprint(item);
    let existing = current_triage_decision_in_tx(transaction, &item.id).await?;
    let Some(cause) = triage_cause(
        existing.as_ref(),
        &fingerprint,
        RUNTIME_RULES_EVALUATOR_IDENTITY,
        active.evaluator_version,
    ) else {
        return match existing {
            // See `apply_builtin_v1_triage_in_tx`'s identical arm: the
            // retained decision's own evaluator identity is the correct
            // placement producer here, not this call's active evaluator.
            Some(existing)
                if !placement_matches_verdict(item, existing.verdict, &existing.evaluator_identity) =>
            {
                let manually_placed = item
                    .lane_origin
                    .as_ref()
                    .is_some_and(TaskBoardLaneOrigin::is_manual);
                if manually_placed || suppress_placement || override_active {
                    Ok(None)
                } else {
                    let producer = existing.evaluator_identity.clone();
                    apply_placement_effect_in_tx(
                        transaction,
                        item,
                        existing.verdict,
                        decided_at,
                        &producer,
                    )
                    .await?;
                    Ok(Some(TriageOutcome::RetainedEffect(existing)))
                }
            }
            _ => Ok(None),
        };
    };
    let decided = evaluate_active_rules(&active, item);
    let decision = record_triage_decision_in_tx(
        transaction,
        &item.id,
        decided.verdict,
        decided.reason_code,
        decided.reason_detail.as_deref(),
        RUNTIME_RULES_EVALUATOR_IDENTITY,
        active.evaluator_version,
        &fingerprint,
        cause,
        decided_at,
    )
    .await?;
    if let TriagePriorityAction::SetTo { priority } = decided.priority_action {
        item.priority = priority;
    }
    let manually_placed = item
        .lane_origin
        .as_ref()
        .is_some_and(TaskBoardLaneOrigin::is_manual);
    if !manually_placed && !suppress_placement && !override_active {
        apply_placement_effect_in_tx(
            transaction,
            item,
            decided.verdict,
            decided_at,
            RUNTIME_RULES_EVALUATOR_IDENTITY,
        )
        .await?;
    }
    Ok(Some(TriageOutcome::Decided(decision)))
}

/// Generalizes [`ensure_current_triage_decision_in_tx`] the same way
/// [`apply_active_triage_in_tx`] generalizes the ingress choke point --
/// delegating verbatim when no custom rule set is active. Deliberately
/// takes `item` by shared reference like the function it generalizes: a
/// rule's `priority_action` never fires here, only on an actual ingress
/// event or a rule-set activation's bulk reevaluation, both of which own a
/// mutable item already.
pub(super) async fn ensure_current_active_triage_decision_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
    decided_at: &str,
) -> Result<Option<EnsuredTriageDecision>, CliError> {
    let Some(active) = load_active_rule_set_in_tx(transaction).await? else {
        return ensure_current_triage_decision_in_tx(transaction, item, decided_at).await;
    };
    if !triage_eligible(item) {
        return Ok(None);
    }
    let fingerprint = evidence_fingerprint(item);
    let existing = current_triage_decision_in_tx(transaction, &item.id).await?;
    let Some(cause) = triage_cause(
        existing.as_ref(),
        &fingerprint,
        RUNTIME_RULES_EVALUATOR_IDENTITY,
        active.evaluator_version,
    ) else {
        return Ok(existing.map(EnsuredTriageDecision::Existing));
    };
    let decided = evaluate_active_rules(&active, item);
    let decision = record_triage_decision_in_tx(
        transaction,
        &item.id,
        decided.verdict,
        decided.reason_code,
        decided.reason_detail.as_deref(),
        RUNTIME_RULES_EVALUATOR_IDENTITY,
        active.evaluator_version,
        &fingerprint,
        cause,
        decided_at,
    )
    .await?;
    Ok(Some(EnsuredTriageDecision::Decided(decision)))
}

#[cfg(test)]
#[path = "triage_apply_rules_tests.rs"]
mod tests;
