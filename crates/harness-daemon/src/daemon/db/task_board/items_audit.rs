use serde_json::json;
use sqlx::{Sqlite, Transaction};
use uuid::Uuid;

use super::super::lane_order::LaneTransitionWrite;
use crate::daemon::db::audit::upsert_audit_event_in_tx;
use crate::daemon::db::{CliError, utc_now};
use crate::daemon::protocol::HarnessMonitorAuditEvent;

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
