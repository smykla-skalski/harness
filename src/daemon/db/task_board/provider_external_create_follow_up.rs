use chrono::{DateTime, Duration, Utc};
use serde_json::{Value, json};
use sqlx::{Sqlite, Transaction, query, query_as};

use super::provider_external_create_rows::{create_conflict, load_intent_by_id};
use crate::daemon::db::audit::UPSERT_AUDIT_EVENT_SQL;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::protocol::HarnessMonitorAuditEvent;
use crate::task_board::{
    ExternalProvider, TaskBoardExternalCreateIntent, TaskBoardExternalCreateIntentState,
    TaskBoardExternalCreateReceipt,
};

const CREATE_FOLLOW_UP_TITLE: &str = "Record provider create receipt";

impl AsyncDaemonDb {
    pub(crate) async fn complete_task_board_external_create_follow_ups(
        &self,
        intents: &[TaskBoardExternalCreateIntent],
    ) -> Result<Vec<HarnessMonitorAuditEvent>, CliError> {
        let mut ordered = intents.to_vec();
        ordered.sort_by(compare_intents);
        ordered.dedup_by(|left, right| left.intent_id == right.intent_id);
        if ordered.is_empty() {
            return Ok(Vec::new());
        }
        let mut transaction = self
            .begin_immediate_transaction("task board external create follow-ups")
            .await?;
        let mut events = Vec::new();
        for intent in &ordered {
            if let Some(event) = complete_one(&mut transaction, intent).await? {
                events.push(event);
            }
        }
        commit(transaction).await?;
        Ok(events)
    }
}

async fn complete_one(
    transaction: &mut Transaction<'_, Sqlite>,
    intent: &TaskBoardExternalCreateIntent,
) -> Result<Option<HarnessMonitorAuditEvent>, CliError> {
    let stored = load_intent_by_id(transaction, &intent.intent_id)
        .await?
        .ok_or_else(|| create_conflict(intent, "create intent is missing"))?;
    if stored != *intent {
        return Err(create_conflict(
            intent,
            "attached create receipt changed before follow-up",
        ));
    }
    let receipt = attached_receipt(&stored)?;
    let completed_at = deterministic_completion_timestamp(&receipt.attached_at)?;
    let event = follow_up_event(&stored, &completed_at);
    if let Some(existing_event_id) = load_follow_up_event_id(transaction, &stored.intent_id).await?
    {
        if existing_event_id == event.id {
            return Ok(None);
        }
        return Err(create_conflict(
            &stored,
            "attached create follow-up has different audit evidence",
        ));
    }
    upsert_audit_event(transaction, &event).await?;
    acknowledge_follow_up(transaction, &stored, receipt, &event.id, &completed_at).await?;
    Ok(Some(event))
}

fn attached_receipt(
    intent: &TaskBoardExternalCreateIntent,
) -> Result<&TaskBoardExternalCreateReceipt, CliError> {
    let TaskBoardExternalCreateIntentState::Attached(receipt) = &intent.state else {
        return Err(create_conflict(
            intent,
            "create intent has no attached receipt",
        ));
    };
    Ok(receipt)
}

async fn acknowledge_follow_up(
    transaction: &mut Transaction<'_, Sqlite>,
    intent: &TaskBoardExternalCreateIntent,
    receipt: &TaskBoardExternalCreateReceipt,
    event_id: &str,
    completed_at: &str,
) -> Result<(), CliError> {
    let updated = query(
        "UPDATE task_board_external_create_intents
         SET follow_up_completed_at = ?4, follow_up_audit_event_id = ?5
         WHERE intent_id = ?1 AND state = 'attached'
           AND attached_at = ?2 AND attached_item_revision = ?3
           AND follow_up_completed_at IS NULL
           AND follow_up_audit_event_id IS NULL",
    )
    .bind(&intent.intent_id)
    .bind(&receipt.attached_at)
    .bind(receipt.attached_item_revision)
    .bind(completed_at)
    .bind(event_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("acknowledge external create follow-up: {error}")))?
    .rows_affected();
    if updated == 1 {
        Ok(())
    } else {
        Err(create_conflict(
            intent,
            "attached create follow-up changed before acknowledgement",
        ))
    }
}

async fn load_follow_up_event_id(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<Option<String>, CliError> {
    query_as::<_, (Option<String>, Option<String>)>(
        "SELECT follow_up_completed_at, follow_up_audit_event_id
         FROM task_board_external_create_intents WHERE intent_id = ?1",
    )
    .bind(intent_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("read external create follow-up: {error}")))
    .and_then(|(completed_at, event_id)| match (completed_at, event_id) {
        (None, None) => Ok(None),
        (Some(_), Some(event_id)) => Ok(Some(event_id)),
        _ => Err(db_error(
            "external create follow-up completion evidence is incomplete",
        )),
    })
}

async fn upsert_audit_event(
    transaction: &mut Transaction<'_, Sqlite>,
    event: &HarnessMonitorAuditEvent,
) -> Result<(), CliError> {
    let payload_json = event.payload_json.as_ref().map(Value::to_string);
    let related_urls_json = serde_json::to_string(&event.related_urls)
        .map_err(|error| db_error(format!("serialize audit related urls: {error}")))?;
    query(UPSERT_AUDIT_EVENT_SQL)
        .bind(&event.id)
        .bind(&event.recorded_at)
        .bind(&event.source)
        .bind(&event.category)
        .bind(&event.kind)
        .bind(&event.severity)
        .bind(&event.outcome)
        .bind(&event.title)
        .bind(&event.summary)
        .bind(event.subject.as_deref())
        .bind(event.actor.as_deref())
        .bind(event.correlation_id.as_deref())
        .bind(event.action_key.as_deref())
        .bind(payload_json.as_deref())
        .bind(event.legacy_message.as_deref())
        .bind(&related_urls_json)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("upsert audit event {}: {error}", event.id)))?;
    Ok(())
}

fn follow_up_event(
    intent: &TaskBoardExternalCreateIntent,
    completed_at: &str,
) -> HarnessMonitorAuditEvent {
    let receipt = attached_receipt(intent).expect("validated attached receipt");
    let reference = &receipt.evidence.outcome.reference;
    HarnessMonitorAuditEvent {
        id: format!("audit-task-board-create-{}", intent.intent_id),
        recorded_at: completed_at.to_owned(),
        source: "taskBoard".to_owned(),
        category: "taskBoardMutation".to_owned(),
        kind: "task_board.external_create_follow_up".to_owned(),
        severity: "info".to_owned(),
        outcome: "success".to_owned(),
        title: CREATE_FOLLOW_UP_TITLE.to_owned(),
        summary: format!(
            "{CREATE_FOLLOW_UP_TITLE} completed for task-board item '{}'",
            intent.item_id
        ),
        subject: Some(intent.item_id.clone()),
        actor: Some("Harness daemon".to_owned()),
        correlation_id: Some(intent.create_key.clone()),
        action_key: Some("task_board.external_create_follow_up".to_owned()),
        payload_json: Some(json!({
            "provider": intent.provider,
            "scope_id": intent.scope_id,
            "item_id": intent.item_id,
            "external_id": reference.external_id,
            "url": reference.url,
            "changed_fields": intent.changed_fields,
            "create_applied": true,
            "operation_count": 0,
            "applied_operation_count": 0,
        })),
        legacy_message: None,
        related_urls: reference.url.iter().cloned().collect(),
    }
}

fn deterministic_completion_timestamp(attached_at: &str) -> Result<String, CliError> {
    let attached = DateTime::parse_from_rfc3339(attached_at)
        .map_err(|error| db_error(format!("parse attached receipt timestamp: {error}")))?
        .with_timezone(&Utc);
    let completed = attached
        .checked_add_signed(Duration::seconds(1))
        .ok_or_else(|| db_error("attached receipt timestamp cannot advance for follow-up"))?;
    let completed = completed.format("%Y-%m-%dT%H:%M:%SZ").to_string();
    if completed.len() == 20 {
        Ok(completed)
    } else {
        Err(db_error(
            "attached receipt timestamp advances beyond the persisted timestamp range",
        ))
    }
}

fn compare_intents(
    left: &TaskBoardExternalCreateIntent,
    right: &TaskBoardExternalCreateIntent,
) -> std::cmp::Ordering {
    provider_label(left.provider)
        .cmp(provider_label(right.provider))
        .then_with(|| left.scope_id.cmp(&right.scope_id))
        .then_with(|| left.updated_at.cmp(&right.updated_at))
        .then_with(|| left.intent_id.cmp(&right.intent_id))
}

const fn provider_label(provider: ExternalProvider) -> &'static str {
    match provider {
        ExternalProvider::GitHub => "github",
        ExternalProvider::Todoist => "todoist",
    }
}

async fn commit(transaction: Transaction<'_, Sqlite>) -> Result<(), CliError> {
    transaction.commit().await.map_err(|error| {
        db_error(format!(
            "commit task-board external create follow-ups: {error}"
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::deterministic_completion_timestamp;

    #[test]
    fn follow_up_timestamp_overflow_fails_closed() {
        deterministic_completion_timestamp("9999-12-31T23:59:59Z")
            .expect_err("maximum timestamp cannot advance");
    }
}
