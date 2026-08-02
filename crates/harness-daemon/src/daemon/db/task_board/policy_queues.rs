//! Database-backed policy event inbox and outboxes.

use chrono::{DateTime, Utc};
use serde::Serialize;
use serde::de::DeserializeOwned;
use sqlx::{Sqlite, Transaction, query, query_as};

use super::POLICY_RUNTIME_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::mapper::{parse_json, to_json};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::policy_runtime::handoff_outbox::HandoffRecord;
use crate::task_board::policy_runtime::models::PolicyWorkflowEvent;
use crate::task_board::policy_runtime::notification::NotificationRecord;
use crate::task_board::policy_runtime::task_creation::TaskCreationRecord;
use crate::daemon::db::prelude::*;

const RETENTION_SECONDS: i64 = 3_600;

#[derive(Clone, Copy)]
struct OutboxSql {
    select: &'static str,
    delete: &'static str,
    insert: &'static str,
}

const HANDOFF_SQL: OutboxSql = OutboxSql {
    select: "SELECT payload_json FROM policy_handoff_outbox ORDER BY record_id",
    delete: "DELETE FROM policy_handoff_outbox",
    insert: "INSERT INTO policy_handoff_outbox (recorded_at, payload_json) VALUES (?1, ?2)",
};
const NOTIFICATION_SQL: OutboxSql = OutboxSql {
    select: "SELECT payload_json FROM policy_notification_outbox ORDER BY record_id",
    delete: "DELETE FROM policy_notification_outbox",
    insert: "INSERT INTO policy_notification_outbox (recorded_at, payload_json) VALUES (?1, ?2)",
};
const TASK_CREATION_SQL: OutboxSql = OutboxSql {
    select: "SELECT payload_json FROM policy_task_creation_outbox ORDER BY record_id",
    delete: "DELETE FROM policy_task_creation_outbox",
    insert: "INSERT INTO policy_task_creation_outbox (recorded_at, payload_json) VALUES (?1, ?2)",
};

/// Real implementations behind the matching [`PolicyRuntimeQueries`] methods,
/// called from the single consolidated trait impl in
/// `policy_runtime_queries.rs` (a trait's methods can only be implemented in
/// one `impl` block per type, so this file hands it plain functions instead
/// of declaring its own `impl PolicyRuntimeQueries for AsyncDaemonDb`).
pub(super) async fn publish_policy_event_at(
    db: &AsyncDaemonDb,
    event: PolicyWorkflowEvent,
    now: DateTime<Utc>,
) -> Result<i64, CliError> {
    let mut transaction = db
        .begin_immediate_transaction("policy event publish")
        .await?;
    let mut events = load_events(transaction.as_mut()).await?;
    events.retain(|stored| {
        !expired(&stored.occurred_at, now)
            && (stored.event_key != event.event_key || stored.subject_key != event.subject_key)
    });
    events.push(event);
    write_events(&mut transaction, &events).await?;
    commit_policy_queue_change(transaction, "policy event publish").await
}

pub(super) async fn pending_policy_events(
    db: &AsyncDaemonDb,
) -> Result<Vec<PolicyWorkflowEvent>, CliError> {
    load_events(db.pool()).await
}

pub(super) async fn remove_delivered_policy_events_at(
    db: &AsyncDaemonDb,
    delivered: &[PolicyWorkflowEvent],
    now: DateTime<Utc>,
) -> Result<i64, CliError> {
    let mut transaction = db
        .begin_immediate_transaction("policy event delivery")
        .await?;
    let mut events = load_events(transaction.as_mut()).await?;
    events.retain(|event| {
        !expired(&event.occurred_at, now) && !delivered.iter().any(|removed| removed == event)
    });
    write_events(&mut transaction, &events).await?;
    commit_policy_queue_change(transaction, "policy event delivery").await
}

pub(super) async fn record_policy_handoff_at(
    db: &AsyncDaemonDb,
    record: HandoffRecord,
    now: DateTime<Utc>,
) -> Result<i64, CliError> {
    append_outbox_record(db, HANDOFF_SQL, "policy handoff", record, now).await
}

pub(super) async fn policy_handoff_records(
    db: &AsyncDaemonDb,
) -> Result<Vec<HandoffRecord>, CliError> {
    load_outbox(db, HANDOFF_SQL, "policy handoff").await
}

pub(super) async fn record_policy_notification_at(
    db: &AsyncDaemonDb,
    record: NotificationRecord,
    now: DateTime<Utc>,
) -> Result<i64, CliError> {
    append_outbox_record(db, NOTIFICATION_SQL, "policy notification", record, now).await
}

pub(super) async fn policy_notification_records(
    db: &AsyncDaemonDb,
) -> Result<Vec<NotificationRecord>, CliError> {
    load_outbox(db, NOTIFICATION_SQL, "policy notification").await
}

pub(super) async fn record_policy_task_creation_at(
    db: &AsyncDaemonDb,
    record: TaskCreationRecord,
    now: DateTime<Utc>,
) -> Result<i64, CliError> {
    append_outbox_record(db, TASK_CREATION_SQL, "policy task creation", record, now).await
}

pub(super) async fn policy_task_creation_records(
    db: &AsyncDaemonDb,
) -> Result<Vec<TaskCreationRecord>, CliError> {
    load_outbox(db, TASK_CREATION_SQL, "policy task creation").await
}

async fn append_outbox_record<T>(
    db: &AsyncDaemonDb,
    sql: OutboxSql,
    context: &'static str,
    record: T,
    now: DateTime<Utc>,
) -> Result<i64, CliError>
where
    T: Serialize + DeserializeOwned + RecordedAt,
{
    let mut transaction = db.begin_immediate_transaction(context).await?;
    let mut records = load_outbox_in_tx(&mut transaction, sql, context).await?;
    records.retain(|stored: &T| !expired(stored.recorded_at(), now));
    records.push(record);
    write_outbox(&mut transaction, sql, context, &records).await?;
    commit_policy_queue_change(transaction, context).await
}

trait RecordedAt {
    fn recorded_at(&self) -> &str;
}

impl RecordedAt for HandoffRecord {
    fn recorded_at(&self) -> &str {
        &self.recorded_at
    }
}

impl RecordedAt for NotificationRecord {
    fn recorded_at(&self) -> &str {
        &self.recorded_at
    }
}

impl RecordedAt for TaskCreationRecord {
    fn recorded_at(&self) -> &str {
        &self.recorded_at
    }
}

async fn load_events<'e, E>(executor: E) -> Result<Vec<PolicyWorkflowEvent>, CliError>
where
    E: sqlx::Executor<'e, Database = Sqlite>,
{
    let rows =
        query_as::<_, (String,)>("SELECT payload_json FROM policy_event_inbox ORDER BY position")
            .fetch_all(executor)
            .await
            .map_err(|error| db_error(format!("load policy event inbox: {error}")))?;
    parse_rows(rows, "policy event")
}

async fn write_events(
    transaction: &mut Transaction<'_, Sqlite>,
    events: &[PolicyWorkflowEvent],
) -> Result<(), CliError> {
    query("DELETE FROM policy_event_inbox")
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("clear policy event inbox: {error}")))?;
    for (position, event) in events.iter().enumerate() {
        query(
            "INSERT INTO policy_event_inbox (
            event_key, subject_key, position, occurred_at, payload_json
        ) VALUES (?1, ?2, ?3, ?4, ?5)",
        )
        .bind(&event.event_key)
        .bind(&event.subject_key)
        .bind(i64::try_from(position).unwrap_or(i64::MAX))
        .bind(&event.occurred_at)
        .bind(to_json(event, "policy event")?)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("insert policy event: {error}")))?;
    }
    Ok(())
}

async fn load_outbox<T>(
    db: &AsyncDaemonDb,
    sql: OutboxSql,
    context: &'static str,
) -> Result<Vec<T>, CliError>
where
    T: DeserializeOwned,
{
    let rows = query_as::<_, (String,)>(sql.select)
        .fetch_all(db.pool())
        .await
        .map_err(|error| db_error(format!("load {context} outbox: {error}")))?;
    parse_rows(rows, context)
}

async fn load_outbox_in_tx<T>(
    transaction: &mut Transaction<'_, Sqlite>,
    sql: OutboxSql,
    context: &'static str,
) -> Result<Vec<T>, CliError>
where
    T: DeserializeOwned,
{
    let rows = query_as::<_, (String,)>(sql.select)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load {context} outbox: {error}")))?;
    parse_rows(rows, context)
}

async fn write_outbox<T: Serialize + RecordedAt>(
    transaction: &mut Transaction<'_, Sqlite>,
    sql: OutboxSql,
    context: &'static str,
    records: &[T],
) -> Result<(), CliError> {
    query(sql.delete)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("clear {context} outbox: {error}")))?;
    for record in records {
        query(sql.insert)
            .bind(record.recorded_at())
            .bind(to_json(record, context)?)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("insert {context} outbox: {error}")))?;
    }
    Ok(())
}

async fn commit_policy_queue_change(
    mut transaction: Transaction<'_, Sqlite>,
    context: &str,
) -> Result<i64, CliError> {
    let revision = bump_change_in_tx(&mut transaction, POLICY_RUNTIME_CHANGE_SCOPE).await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit {context}: {error}")))?;
    Ok(revision)
}

fn parse_rows<T: DeserializeOwned>(
    rows: Vec<(String,)>,
    context: &str,
) -> Result<Vec<T>, CliError> {
    rows.into_iter()
        .map(|row| parse_json(&row.0, context))
        .collect()
}

fn expired(recorded_at: &str, now: DateTime<Utc>) -> bool {
    let Some(recorded) = policy_queue_timestamp(recorded_at) else {
        return true;
    };
    now.signed_duration_since(recorded).num_seconds() > RETENTION_SECONDS
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn policy_queue_timestamp(recorded_at: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(recorded_at)
        .inspect_err(|error| {
            tracing::warn!(recorded_at, %error, "dropping policy queue record with invalid timestamp");
        })
        .ok()
        .map(|recorded| recorded.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use chrono::Duration;

    use super::*;

    #[test]
    fn malformed_policy_queue_timestamp_is_expired() {
        let now = "2026-07-11T10:00:00Z"
            .parse::<DateTime<Utc>>()
            .expect("timestamp");

        assert!(expired("not-a-timestamp", now));
    }

    #[test]
    fn policy_queue_retention_boundary_is_preserved() {
        let now = "2026-07-11T10:00:00Z"
            .parse::<DateTime<Utc>>()
            .expect("timestamp");

        assert!(!expired(
            &(now - Duration::seconds(RETENTION_SECONDS)).to_rfc3339(),
            now
        ));
        assert!(expired(
            &(now - Duration::seconds(RETENTION_SECONDS + 1)).to_rfc3339(),
            now
        ));
        assert!(!expired(&(now + Duration::seconds(1)).to_rfc3339(), now));
    }
}
