use super::{
    INSERT_LOG_ENTRY_SQL, NEXT_LOG_SEQUENCE_SQL, SessionLogEntry, UPSERT_TIMELINE_ENTRY_SQL,
    UPSERT_TIMELINE_STATE_SQL, daemon_timeline, db_error, i64_from_u64, query, query_scalar,
    stored_timeline_entry, u64_from_i64, utc_now,
};
use super::{Sqlite, Transaction};
use crate::daemon::db::StoredTimelineEntry;
use crate::errors::CliError;

pub(super) async fn next_log_sequence(
    transaction: &mut Transaction<'_, Sqlite>,
    entry: &SessionLogEntry,
) -> Result<u64, CliError> {
    if entry.sequence != 0 {
        return Ok(entry.sequence);
    }
    query_scalar::<_, i64>(NEXT_LOG_SEQUENCE_SQL)
        .bind(&entry.session_id)
        .fetch_one(transaction.as_mut())
        .await
        .map(u64_from_i64)
        .map_err(|error| db_error(format!("next async log sequence: {error}")))
}

pub(super) async fn insert_log_entry(
    transaction: &mut Transaction<'_, Sqlite>,
    entry: &SessionLogEntry,
    sequence: u64,
    transition_json: &str,
    transition_kind: &str,
) -> Result<bool, CliError> {
    query(INSERT_LOG_ENTRY_SQL)
        .bind(&entry.session_id)
        .bind(i64_from_u64(sequence))
        .bind(&entry.recorded_at)
        .bind(transition_kind)
        .bind(transition_json)
        .bind(entry.actor_id.as_deref())
        .bind(entry.reason.as_deref())
        .execute(transaction.as_mut())
        .await
        .map(|result| result.rows_affected() > 0)
        .map_err(|error| db_error(format!("append async log entry: {error}")))
}

pub(super) async fn persist_log_timeline(
    transaction: &mut Transaction<'_, Sqlite>,
    entry: &SessionLogEntry,
    sequence: u64,
) -> Result<(), CliError> {
    let timeline_entry = daemon_timeline::log_entry_timeline_entry(
        &SessionLogEntry {
            sequence,
            ..entry.clone()
        },
        daemon_timeline::TimelinePayloadScope::Full,
    )?;
    let stored = stored_timeline_entry("log", format!("log:{sequence}"), &timeline_entry)?;
    upsert_timeline_entry(transaction, &stored).await?;
    query(UPSERT_TIMELINE_STATE_SQL)
        .bind(&entry.session_id)
        .bind(utc_now())
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("persist async timeline state: {error}")))?;
    Ok(())
}

pub(super) async fn upsert_timeline_entry(
    transaction: &mut Transaction<'_, Sqlite>,
    entry: &StoredTimelineEntry,
) -> Result<(), CliError> {
    query(UPSERT_TIMELINE_ENTRY_SQL)
        .bind(&entry.session_id)
        .bind(&entry.entry_id)
        .bind(&entry.source_kind)
        .bind(&entry.source_key)
        .bind(&entry.recorded_at)
        .bind(&entry.kind)
        .bind(entry.agent_id.as_deref())
        .bind(entry.task_id.as_deref())
        .bind(&entry.summary)
        .bind(&entry.payload_json)
        .bind(&entry.sort_recorded_at)
        .bind(&entry.sort_tiebreaker)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("upsert async timeline entry: {error}")))?;
    Ok(())
}
