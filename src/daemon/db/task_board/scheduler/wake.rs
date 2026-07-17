use std::collections::BTreeSet;

use chrono::{DateTime, Utc};
use sqlx::{QueryBuilder, Sqlite, query, query_as};

use super::super::ORCHESTRATOR_CHANGE_SCOPE;
use super::super::items::bump_change_in_tx;
use super::super::mapper::{parse_json, to_json};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::{
    TASK_BOARD_AUTOMATION_WAKE_BATCH_LIMIT, TASK_BOARD_AUTOMATION_WAKE_PAYLOAD_SCHEMA_VERSION,
    TaskBoardAutomationLedgerChangedWakeV1, TaskBoardAutomationRecoveryWakeV1,
    TaskBoardAutomationWakeCause, TaskBoardAutomationWakeEvent, TaskBoardAutomationWakePayload,
    TaskBoardAutomationWakeRequest,
};

const PROCESSED_WAKE_RETENTION_LIMIT: i64 = 500;

#[derive(sqlx::FromRow)]
pub(super) struct TaskBoardAutomationWakeRow {
    pub(super) sequence: i64,
    pub(super) cause: String,
    pub(super) entity_id: Option<String>,
    pub(super) entity_revision: Option<i64>,
    pub(super) payload_json: String,
    pub(super) created_at: String,
    pub(super) processed_at: Option<String>,
}

pub(super) struct TaskBoardAutomationWakeObservation {
    pub(super) event: TaskBoardAutomationWakeEvent,
    pub(super) processed_at: Option<String>,
}

#[derive(sqlx::FromRow)]
struct WakeAcknowledgementRow {
    sequence: i64,
    processed_at: Option<String>,
}

impl AsyncDaemonDb {
    pub(crate) async fn enqueue_task_board_automation_wake_event(
        &self,
        request: &TaskBoardAutomationWakeRequest,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationWakeEvent, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board automation wake enqueue")
            .await?;
        let event = enqueue_in_tx(&mut transaction, request, now).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit task board automation wake enqueue: {error}"
            ))
        })?;
        Ok(event)
    }

    pub(crate) async fn pending_task_board_automation_wake_events(
        &self,
        limit: u32,
    ) -> Result<Vec<TaskBoardAutomationWakeEvent>, CliError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let rows = query_as::<_, TaskBoardAutomationWakeRow>(
            "SELECT sequence, cause, entity_id, entity_revision, payload_json, created_at,
                    processed_at
             FROM task_board_orchestrator_wake_events
             WHERE processed_at IS NULL ORDER BY sequence
             LIMIT ?1",
        )
        .bind(i64::from(limit.min(TASK_BOARD_AUTOMATION_WAKE_BATCH_LIMIT)))
        .fetch_all(self.pool())
        .await
        .map_err(|error| db_error(format!("load pending task board wake events: {error}")))?;
        rows.into_iter()
            .map(decode_task_board_automation_wake_row)
            .map(|observation| observation.map(|observation| observation.event))
            .collect()
    }

    pub(crate) async fn acknowledge_task_board_automation_wake_events(
        &self,
        sequences: &[u64],
        processed_at: DateTime<Utc>,
    ) -> Result<u64, CliError> {
        let sequences = normalize_sequences(sequences)?;
        if sequences.is_empty() {
            return Ok(0);
        }
        let mut transaction = self
            .begin_immediate_transaction("task board automation wake acknowledgement")
            .await?;
        let rows = load_acknowledgement_rows(&mut transaction, &sequences).await?;
        validate_acknowledgement_rows(&sequences, &rows)?;
        let pending = rows
            .into_iter()
            .filter(|row| row.processed_at.is_none())
            .map(|row| row.sequence)
            .collect::<Vec<_>>();
        let changed = acknowledge_pending_rows(&mut transaction, &pending, processed_at).await?;
        if changed > 0 {
            prune_processed_rows(&mut transaction).await?;
            bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        }
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit task board automation wake acknowledgement: {error}"
            ))
        })?;
        Ok(changed)
    }
}

pub(super) async fn enqueue_in_tx(
    transaction: &mut sqlx::Transaction<'_, Sqlite>,
    request: &TaskBoardAutomationWakeRequest,
    now: DateTime<Utc>,
) -> Result<TaskBoardAutomationWakeEvent, CliError> {
    validate_wake(
        request.entity_id.as_deref(),
        request.entity_revision,
        &request.payload,
    )?;
    let cause = cause_label(request.payload.cause());
    let entity_revision = request
        .entity_revision
        .map(|revision| stored_integer(revision, "wake entity revision"))
        .transpose()?;
    let payload_json = encode_payload(&request.payload)?;
    if let Some(row) = load_duplicate(
        transaction,
        cause,
        request.entity_id.as_deref(),
        entity_revision,
        &payload_json,
    )
    .await?
    {
        return decode_task_board_automation_wake_row(row).map(|value| value.event);
    }
    let created_at = now.to_rfc3339();
    let inserted = query(
        "INSERT INTO task_board_orchestrator_wake_events (
            cause, entity_id, entity_revision, payload_json, created_at
         ) VALUES (?1, ?2, ?3, ?4, ?5)",
    )
    .bind(cause)
    .bind(request.entity_id.as_deref())
    .bind(entity_revision)
    .bind(&payload_json)
    .bind(&created_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("enqueue task board automation wake event: {error}")))?;
    let sequence = event_sequence(inserted.last_insert_rowid())?;
    bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    Ok(TaskBoardAutomationWakeEvent {
        sequence,
        entity_id: request.entity_id.clone(),
        entity_revision: request.entity_revision,
        payload: request.payload.clone(),
        created_at,
    })
}

async fn load_duplicate(
    transaction: &mut sqlx::Transaction<'_, Sqlite>,
    cause: &str,
    entity_id: Option<&str>,
    entity_revision: Option<i64>,
    payload_json: &str,
) -> Result<Option<TaskBoardAutomationWakeRow>, CliError> {
    query_as::<_, TaskBoardAutomationWakeRow>(
        "SELECT sequence, cause, entity_id, entity_revision, payload_json, created_at,
                processed_at
         FROM task_board_orchestrator_wake_events
         WHERE processed_at IS NULL AND cause = ?1 AND entity_id IS ?2
           AND entity_revision IS ?3 AND payload_json = ?4
         ORDER BY sequence LIMIT 1",
    )
    .bind(cause)
    .bind(entity_id)
    .bind(entity_revision)
    .bind(payload_json)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load duplicate task board wake event: {error}")))
}

async fn load_acknowledgement_rows(
    transaction: &mut sqlx::Transaction<'_, Sqlite>,
    sequences: &[i64],
) -> Result<Vec<WakeAcknowledgementRow>, CliError> {
    let mut builder = QueryBuilder::<Sqlite>::new(
        "SELECT sequence, processed_at FROM task_board_orchestrator_wake_events WHERE sequence IN (",
    );
    push_sequence_set(&mut builder, sequences);
    builder.push(") ORDER BY sequence");
    builder
        .build_query_as::<WakeAcknowledgementRow>()
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load task board wake acknowledgements: {error}")))
}

fn validate_acknowledgement_rows(
    requested: &[i64],
    rows: &[WakeAcknowledgementRow],
) -> Result<(), CliError> {
    let stored = rows.iter().map(|row| row.sequence).collect::<Vec<_>>();
    if stored != requested {
        return Err(db_error(
            "task board wake acknowledgement contains an unknown sequence",
        ));
    }
    for row in rows {
        if let Some(processed_at) = row.processed_at.as_deref() {
            parse_timestamp(processed_at, "task board wake processed timestamp")?;
        }
    }
    Ok(())
}

async fn acknowledge_pending_rows(
    transaction: &mut sqlx::Transaction<'_, Sqlite>,
    sequences: &[i64],
    processed_at: DateTime<Utc>,
) -> Result<u64, CliError> {
    if sequences.is_empty() {
        return Ok(0);
    }
    let mut builder = QueryBuilder::<Sqlite>::new(
        "UPDATE task_board_orchestrator_wake_events SET processed_at = ",
    );
    builder.push_bind(processed_at.to_rfc3339());
    builder.push(" WHERE processed_at IS NULL AND sequence IN (");
    push_sequence_set(&mut builder, sequences);
    builder.push(")");
    let changed = builder
        .build()
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("acknowledge task board wake events: {error}")))?
        .rows_affected();
    let expected = u64::try_from(sequences.len())
        .map_err(|error| db_error(format!("count task board wake acknowledgements: {error}")))?;
    if changed != expected {
        return Err(db_error(
            "task board wake acknowledgement changed an unexpected sequence set",
        ));
    }
    Ok(changed)
}

async fn prune_processed_rows(
    transaction: &mut sqlx::Transaction<'_, Sqlite>,
) -> Result<(), CliError> {
    query(
        "DELETE FROM task_board_orchestrator_wake_events
         WHERE processed_at IS NOT NULL
           AND sequence NOT IN (
               SELECT sequence FROM task_board_orchestrator_wake_events
               WHERE processed_at IS NOT NULL
               ORDER BY sequence DESC LIMIT ?1
           )",
    )
    .bind(PROCESSED_WAKE_RETENTION_LIMIT)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("prune processed task board wake events: {error}")))
}

fn push_sequence_set(builder: &mut QueryBuilder<Sqlite>, sequences: &[i64]) {
    let mut separated = builder.separated(", ");
    for sequence in sequences {
        separated.push_bind(*sequence);
    }
}

fn normalize_sequences(sequences: &[u64]) -> Result<Vec<i64>, CliError> {
    let unique = sequences.iter().copied().collect::<BTreeSet<_>>();
    if unique.len() > usize::try_from(TASK_BOARD_AUTOMATION_WAKE_BATCH_LIMIT).unwrap_or(usize::MAX)
    {
        return Err(db_error("too many task board wake acknowledgements"));
    }
    unique
        .into_iter()
        .map(|sequence| stored_integer(sequence, "wake sequence"))
        .collect()
}

pub(super) fn decode_task_board_automation_wake_row(
    row: TaskBoardAutomationWakeRow,
) -> Result<TaskBoardAutomationWakeObservation, CliError> {
    let sequence = event_sequence(row.sequence)?;
    let entity_revision = row
        .entity_revision
        .map(|revision| event_revision(revision, sequence))
        .transpose()?;
    let payload = decode_payload(&row.cause, &row.payload_json, sequence)?;
    parse_timestamp(&row.created_at, "task board wake created timestamp")?;
    if let Some(processed_at) = row.processed_at.as_deref() {
        parse_timestamp(processed_at, "task board wake processed timestamp")?;
    }
    validate_wake(row.entity_id.as_deref(), entity_revision, &payload)?;
    Ok(TaskBoardAutomationWakeObservation {
        event: TaskBoardAutomationWakeEvent {
            sequence,
            entity_id: row.entity_id,
            entity_revision,
            payload,
            created_at: row.created_at,
        },
        processed_at: row.processed_at,
    })
}

fn validate_wake(
    entity_id: Option<&str>,
    entity_revision: Option<u64>,
    payload: &TaskBoardAutomationWakePayload,
) -> Result<(), CliError> {
    if entity_id.is_some_and(|value| value.trim().is_empty()) {
        return Err(db_error("task board wake event has an empty entity id"));
    }
    if entity_revision.is_some() && entity_id.is_none() {
        return Err(db_error(
            "task board wake event revision requires an entity id",
        ));
    }
    match payload {
        TaskBoardAutomationWakePayload::LedgerChanged(value) => {
            validate_schema(value.schema_version)?;
            if entity_id.is_none() {
                return Err(db_error("task board ledger wake requires an entity id"));
            }
        }
        TaskBoardAutomationWakePayload::Recovery(value) => validate_schema(value.schema_version)?,
    }
    Ok(())
}

fn validate_schema(schema_version: u32) -> Result<(), CliError> {
    if schema_version != TASK_BOARD_AUTOMATION_WAKE_PAYLOAD_SCHEMA_VERSION {
        return Err(db_error(format!(
            "unsupported task board wake payload schema v{schema_version}"
        )));
    }
    Ok(())
}

fn encode_payload(payload: &TaskBoardAutomationWakePayload) -> Result<String, CliError> {
    match payload {
        TaskBoardAutomationWakePayload::LedgerChanged(value) => {
            to_json(value, "task board ledger wake payload")
        }
        TaskBoardAutomationWakePayload::Recovery(value) => {
            to_json(value, "task board recovery wake payload")
        }
    }
}

fn decode_payload(
    cause: &str,
    value: &str,
    sequence: u64,
) -> Result<TaskBoardAutomationWakePayload, CliError> {
    let context = format!("task board wake payload {sequence}");
    match parse_cause(cause)? {
        TaskBoardAutomationWakeCause::LedgerChanged => {
            parse_json::<TaskBoardAutomationLedgerChangedWakeV1>(value, &context)
                .map(TaskBoardAutomationWakePayload::LedgerChanged)
        }
        TaskBoardAutomationWakeCause::Recovery => {
            parse_json::<TaskBoardAutomationRecoveryWakeV1>(value, &context)
                .map(TaskBoardAutomationWakePayload::Recovery)
        }
    }
}

const fn cause_label(cause: TaskBoardAutomationWakeCause) -> &'static str {
    match cause {
        TaskBoardAutomationWakeCause::LedgerChanged => "ledger_changed",
        TaskBoardAutomationWakeCause::Recovery => "recovery",
    }
}

fn parse_cause(value: &str) -> Result<TaskBoardAutomationWakeCause, CliError> {
    match value {
        "ledger_changed" => Ok(TaskBoardAutomationWakeCause::LedgerChanged),
        "recovery" => Ok(TaskBoardAutomationWakeCause::Recovery),
        value => Err(db_error(format!(
            "invalid task board automation wake cause '{value}'"
        ))),
    }
}

fn parse_timestamp(value: &str, context: &str) -> Result<(), CliError> {
    DateTime::parse_from_rfc3339(value)
        .map(|_| ())
        .map_err(|error| db_error(format!("parse {context}: {error}")))
}

fn stored_integer(value: u64, context: &str) -> Result<i64, CliError> {
    i64::try_from(value).map_err(|error| db_error(format!("convert task board {context}: {error}")))
}

fn event_sequence(value: i64) -> Result<u64, CliError> {
    let sequence = u64::try_from(value)
        .map_err(|error| db_error(format!("parse task board wake sequence: {error}")))?;
    if sequence == 0 {
        return Err(db_error("task board wake sequence must be positive"));
    }
    Ok(sequence)
}

fn event_revision(value: i64, sequence: u64) -> Result<u64, CliError> {
    u64::try_from(value).map_err(|error| {
        db_error(format!(
            "parse task board wake entity revision {sequence}: {error}"
        ))
    })
}
