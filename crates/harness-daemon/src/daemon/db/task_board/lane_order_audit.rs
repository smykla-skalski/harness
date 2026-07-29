use serde_json::json;
use sqlx::{Sqlite, Transaction};
use uuid::Uuid;

use super::lane_order::{LaneTransitionWrite, TaskBoardLanePositionAuditKind};
use crate::daemon::db::audit::upsert_audit_event_in_tx;
use crate::daemon::db::{CliError, utc_now};
use crate::daemon::protocol::HarnessMonitorAuditEvent;
use crate::task_board::TaskBoardItem;

pub(super) async fn record_lane_position_audit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    before: &TaskBoardItem,
    write: &LaneTransitionWrite,
    items_change_seq: i64,
    actor: &str,
    kind: TaskBoardLanePositionAuditKind,
) -> Result<(), CliError> {
    let (event_kind, title, summary) = match kind {
        TaskBoardLanePositionAuditKind::Set => (
            "task_board.item.position_set",
            "Task Board position set",
            "Set task-board position",
        ),
        TaskBoardLanePositionAuditKind::Reset => (
            "task_board.item.position_reset",
            "Task Board position reset",
            "Reset task-board position",
        ),
    };
    let event = HarnessMonitorAuditEvent {
        id: format!("audit-{}", Uuid::new_v4().simple()),
        recorded_at: utc_now(),
        source: "taskBoard".into(),
        category: "task_board".into(),
        kind: event_kind.into(),
        severity: "info".into(),
        outcome: "success".into(),
        title: title.into(),
        summary: format!("{summary} for {}", write.item.id),
        subject: Some(write.item.id.clone()),
        actor: Some(actor.to_owned()),
        correlation_id: None,
        action_key: Some(event_kind.into()),
        payload_json: Some(json!({
            "item_id": write.item.id,
            "item_revision": write.item_revision,
            "items_change_seq": items_change_seq,
            "actor": actor,
            "from": lane_position_audit_value(before),
            "to": lane_position_audit_value(&write.item),
            "origin": write.item.lane_origin.clone(),
            "set_at": write.item.lane_set_at.clone(),
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

fn lane_position_audit_value(item: &TaskBoardItem) -> serde_json::Value {
    json!({
        "lane": item.status.canonical_persisted_status(),
        "index": item.lane_position,
    })
}
