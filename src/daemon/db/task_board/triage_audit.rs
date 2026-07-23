use serde_json::json;
use sqlx::{Sqlite, Transaction};
use uuid::Uuid;

use super::lane_order::LaneTransitionWrite;
use crate::daemon::db::audit::upsert_audit_event_in_tx;
use crate::daemon::db::{CliError, utc_now};
use crate::daemon::protocol::HarnessMonitorAuditEvent;
use crate::task_board::{TaskBoardItem, TaskBoardTriageDecision};

/// One semantic audit event for a fresh `BuiltInV1` decision (a new history
/// generation), plus whatever placement effect (or lack of one, under
/// manual/suppressed placement) it produced in the same transaction.
/// Replaces the generic lane-position audit for this write so a
/// triage-driven change is never double-audited under two different event
/// kinds.
pub(super) async fn record_triage_decided_audit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    before: &TaskBoardItem,
    decision: &TaskBoardTriageDecision,
    write: &LaneTransitionWrite,
    items_change_seq: i64,
) -> Result<(), CliError> {
    record_triage_outcome_audit_in_tx(
        transaction,
        "task_board.item.triage_decided",
        "Task Board triage decided",
        before,
        decision,
        write,
        items_change_seq,
    )
    .await
}

/// One semantic audit event for an existing decision whose placement effect
/// was merely reapplied (no new history generation) -- a reused decision
/// must never be reported as `triage_decided`.
pub(super) async fn record_triage_effect_reapplied_audit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    before: &TaskBoardItem,
    decision: &TaskBoardTriageDecision,
    write: &LaneTransitionWrite,
    items_change_seq: i64,
) -> Result<(), CliError> {
    record_triage_outcome_audit_in_tx(
        transaction,
        "task_board.item.triage_effect_reapplied",
        "Task Board triage effect reapplied",
        before,
        decision,
        write,
        items_change_seq,
    )
    .await
}

async fn record_triage_outcome_audit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    kind: &'static str,
    title: &'static str,
    before: &TaskBoardItem,
    decision: &TaskBoardTriageDecision,
    write: &LaneTransitionWrite,
    items_change_seq: i64,
) -> Result<(), CliError> {
    let event = HarnessMonitorAuditEvent {
        id: format!("audit-{}", Uuid::new_v4().simple()),
        recorded_at: utc_now(),
        source: "taskBoard".into(),
        category: "task_board".into(),
        kind: kind.into(),
        severity: "info".into(),
        outcome: "success".into(),
        title: title.into(),
        summary: format!("BuiltInV1 {:?} for {}", decision.verdict, write.item.id),
        subject: Some(write.item.id.clone()),
        actor: Some(decision.evaluator_identity.clone()),
        correlation_id: None,
        action_key: Some(kind.into()),
        payload_json: Some(json!({
            "item_id": write.item.id,
            "item_revision": write.item_revision,
            "items_change_seq": items_change_seq,
            "decision": {
                "verdict": decision.verdict,
                "reason_code": decision.reason_code,
                "cause": decision.cause,
                "evaluator_identity": decision.evaluator_identity,
                "evaluator_version": decision.evaluator_version,
                "decided_at": decision.decided_at,
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

/// One semantic audit event for a provider-exclusion hide, even when the
/// item had no lane anchor to change (a default Backlog item, for example):
/// the exclusion itself is the consequential change, not just whatever
/// placement side effect it happened to also produce. No human actor is
/// recorded -- the transport has not authenticated one for a provider sync.
pub(super) async fn record_provider_exclusion_hidden_audit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    before: &TaskBoardItem,
    write: &LaneTransitionWrite,
    items_change_seq: i64,
) -> Result<(), CliError> {
    const KIND: &str = "task_board.item.provider_exclusion_hidden";
    let event = HarnessMonitorAuditEvent {
        id: format!("audit-{}", Uuid::new_v4().simple()),
        recorded_at: utc_now(),
        source: "taskBoard".into(),
        category: "task_board".into(),
        kind: KIND.into(),
        severity: "info".into(),
        outcome: "success".into(),
        title: "Task Board provider exclusion hidden".into(),
        summary: format!("Provider exclusion hid {}", write.item.id),
        subject: Some(write.item.id.clone()),
        actor: None,
        correlation_id: None,
        action_key: Some(KIND.into()),
        payload_json: Some(json!({
            "item_id": write.item.id,
            "item_revision": write.item_revision,
            "items_change_seq": items_change_seq,
            "tombstone_cause": write.item.tombstone_cause,
            "placement": {
                "from": placement_audit_value(before),
                "to": placement_audit_value(&write.item),
            },
        })),
        legacy_message: None,
        related_urls: Vec::new(),
    };
    upsert_audit_event_in_tx(transaction, &event).await
}

/// One semantic audit event for a public create through the human or
/// provider ingress paths that produced no triage decision either way (an
/// ineligible item, for example). Emitted unconditionally, unlike the plain
/// lane-transition audit, so a public no-op create is never silently
/// unaudited.
pub(super) async fn record_item_created_audit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    write: &LaneTransitionWrite,
    items_change_seq: i64,
) -> Result<(), CliError> {
    record_ordinary_mutation_audit_in_tx(
        transaction,
        "task_board.item.created",
        "Task Board item created",
        write,
        items_change_seq,
    )
    .await
}

/// Like [`record_item_created_audit_in_tx`], for a public update that
/// produced no triage decision either way.
pub(super) async fn record_item_updated_audit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    write: &LaneTransitionWrite,
    items_change_seq: i64,
) -> Result<(), CliError> {
    record_ordinary_mutation_audit_in_tx(
        transaction,
        "task_board.item.updated",
        "Task Board item updated",
        write,
        items_change_seq,
    )
    .await
}

async fn record_ordinary_mutation_audit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    kind: &'static str,
    title: &'static str,
    write: &LaneTransitionWrite,
    items_change_seq: i64,
) -> Result<(), CliError> {
    let event = HarnessMonitorAuditEvent {
        id: format!("audit-{}", Uuid::new_v4().simple()),
        recorded_at: utc_now(),
        source: "taskBoard".into(),
        category: "task_board".into(),
        kind: kind.into(),
        severity: "info".into(),
        outcome: "success".into(),
        title: title.into(),
        summary: format!("{title} for {}", write.item.id),
        subject: Some(write.item.id.clone()),
        actor: None,
        correlation_id: None,
        action_key: Some(kind.into()),
        payload_json: Some(json!({
            "item_id": write.item.id,
            "item_revision": write.item_revision,
            "items_change_seq": items_change_seq,
        })),
        legacy_message: None,
        related_urls: Vec::new(),
    };
    upsert_audit_event_in_tx(transaction, &event).await
}

fn placement_audit_value(item: &TaskBoardItem) -> serde_json::Value {
    json!({
        "lane": item.status.canonical_persisted_status(),
        "index": item.lane_position,
        "origin": item.lane_origin,
    })
}
