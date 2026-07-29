use serde_json::json;
use sqlx::{Sqlite, Transaction};
use uuid::Uuid;

use super::lane_order::LaneTransitionWrite;
use super::triage_apply::EnsuredTriageDecision;
use crate::daemon::db::audit::upsert_audit_event_in_tx;
use crate::daemon::db::{CliError, utc_now};
use crate::daemon::protocol::HarnessMonitorAuditEvent;
use crate::task_board::{TaskBoardItem, TaskBoardTriageEffectiveOutcome, TaskBoardTriageOverride};

fn effective_audit_value(outcome: Option<TaskBoardTriageEffectiveOutcome>) -> serde_json::Value {
    match outcome {
        Some(outcome) => json!({
            "verdict": outcome.verdict,
            "source": outcome.source,
        }),
        None => serde_json::Value::Null,
    }
}

fn placement_audit_value(item: &TaskBoardItem) -> serde_json::Value {
    json!({
        "lane": item.status.canonical_persisted_status(),
        "index": item.lane_position,
        "origin": item.lane_origin,
    })
}

fn automatic_decision_audit_value(outcome: Option<&EnsuredTriageDecision>) -> serde_json::Value {
    let Some(outcome) = outcome else {
        return json!({
            "outcome_kind": "none",
            "decision": null,
        });
    };
    let decision = outcome.decision();
    json!({
        "outcome_kind": outcome.outcome_kind(),
        "decision": {
            "verdict": decision.verdict,
            "reason_code": decision.reason_code,
            "evaluator_identity": decision.evaluator_identity,
            "evaluator_version": decision.evaluator_version,
            "cause": decision.cause,
            "decided_at": decision.decided_at,
        },
    })
}

/// One semantic audit event for an override set (or updated verdict/reason
/// on an already-active override), capturing the CAS pair the caller
/// proved, the effective outcome before and after, and the resulting row
/// revision and item-list sequence.
#[expect(
    clippy::too_many_arguments,
    reason = "one immutable audit row needs before/after/override/CAS context together"
)]
pub(super) async fn record_triage_override_set_audit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    before: &TaskBoardItem,
    before_effective: Option<TaskBoardTriageEffectiveOutcome>,
    override_: &TaskBoardTriageOverride,
    after_effective: Option<TaskBoardTriageEffectiveOutcome>,
    write: &LaneTransitionWrite,
    items_change_seq: i64,
    expected_item_revision: i64,
    expected_items_change_seq: i64,
) -> Result<(), CliError> {
    const KIND: &str = "task_board.item.triage_override_set";
    let event = HarnessMonitorAuditEvent {
        id: format!("audit-{}", Uuid::new_v4().simple()),
        recorded_at: utc_now(),
        source: "taskBoard".into(),
        category: "task_board".into(),
        kind: KIND.into(),
        severity: "info".into(),
        outcome: "success".into(),
        title: "Task Board triage override set".into(),
        summary: format!(
            "Triage override set to {:?} for {}",
            override_.verdict, write.item.id
        ),
        subject: Some(write.item.id.clone()),
        actor: Some(override_.actor.clone()),
        correlation_id: None,
        action_key: Some(KIND.into()),
        payload_json: Some(json!({
            "item_id": write.item.id,
            "item_revision": write.item_revision,
            "items_change_seq": items_change_seq,
            "cas": {
                "expected_item_revision": expected_item_revision,
                "expected_items_change_seq": expected_items_change_seq,
            },
            "override": {
                "verdict": override_.verdict,
                "actor": override_.actor,
                "reason": override_.reason,
                "set_at": override_.set_at,
            },
            "effective": {
                "before": effective_audit_value(before_effective),
                "after": effective_audit_value(after_effective),
            },
            "placement": {
                "from": placement_audit_value(before),
                "to": placement_audit_value(&write.item),
            },
            "shifted": write.shifted.iter().map(|shift| json!({
                "item_id": shift.item_id,
                "item_revision": shift.item_revision,
            })).collect::<Vec<_>>(),
        })),
        legacy_message: None,
        related_urls: Vec::new(),
    };
    upsert_audit_event_in_tx(transaction, &event).await
}

/// One semantic audit event for an override clear, capturing the cleared
/// override, whether the automatic decision was refreshed or reused,
/// whether its placement was reconciled, and the CAS pair proved.
#[expect(
    clippy::too_many_arguments,
    reason = "one immutable audit row needs before/after/override/CAS/actor context together"
)]
pub(super) async fn record_triage_override_cleared_audit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    before: &TaskBoardItem,
    cleared: &TaskBoardTriageOverride,
    before_effective: Option<TaskBoardTriageEffectiveOutcome>,
    after_effective: Option<TaskBoardTriageEffectiveOutcome>,
    automatic_decision: Option<&EnsuredTriageDecision>,
    reconciled: bool,
    write: &LaneTransitionWrite,
    items_change_seq: i64,
    expected_item_revision: i64,
    expected_items_change_seq: i64,
    actor: &str,
) -> Result<(), CliError> {
    const KIND: &str = "task_board.item.triage_override_cleared";
    let event = HarnessMonitorAuditEvent {
        id: format!("audit-{}", Uuid::new_v4().simple()),
        recorded_at: utc_now(),
        source: "taskBoard".into(),
        category: "task_board".into(),
        kind: KIND.into(),
        severity: "info".into(),
        outcome: "success".into(),
        title: "Task Board triage override cleared".into(),
        summary: format!("Triage override cleared for {}", write.item.id),
        subject: Some(write.item.id.clone()),
        actor: Some(actor.to_owned()),
        correlation_id: None,
        action_key: Some(KIND.into()),
        payload_json: Some(json!({
            "item_id": write.item.id,
            "item_revision": write.item_revision,
            "items_change_seq": items_change_seq,
            "cas": {
                "expected_item_revision": expected_item_revision,
                "expected_items_change_seq": expected_items_change_seq,
            },
            "cleared_override": {
                "verdict": cleared.verdict,
                "actor": cleared.actor,
                "reason": cleared.reason,
                "set_at": cleared.set_at,
            },
            "reconciled": reconciled,
            "automatic_decision": automatic_decision_audit_value(automatic_decision),
            "effective": {
                "before": effective_audit_value(before_effective),
                "after": effective_audit_value(after_effective),
            },
            "placement": {
                "from": placement_audit_value(before),
                "to": placement_audit_value(&write.item),
            },
            "shifted": write.shifted.iter().map(|shift| json!({
                "item_id": shift.item_id,
                "item_revision": shift.item_revision,
            })).collect::<Vec<_>>(),
        })),
        legacy_message: None,
        related_urls: Vec::new(),
    };
    upsert_audit_event_in_tx(transaction, &event).await
}
