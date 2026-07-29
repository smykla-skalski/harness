use serde_json::Value;
use sqlx::{QueryBuilder, Sqlite, Transaction, query};

use crate::daemon::protocol::{
    HarnessMonitorAuditEvent, HarnessMonitorAuditEventsRequest, HarnessMonitorAuditEventsResponse,
};

use super::{AsyncDaemonDb, CliError, db_error};

#[allow(dead_code)]
pub(in crate::daemon::db) const UPSERT_AUDIT_EVENT_SQL: &str = "
INSERT INTO audit_events (
    id, recorded_at, source, category, kind, severity, outcome, title, summary,
    subject, actor, correlation_id, action_key, payload_json, legacy_message, related_urls_json
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
ON CONFLICT(id) DO UPDATE SET
    recorded_at = excluded.recorded_at,
    source = excluded.source,
    category = excluded.category,
    kind = excluded.kind,
    severity = excluded.severity,
    outcome = excluded.outcome,
    title = excluded.title,
    summary = excluded.summary,
    subject = excluded.subject,
    actor = excluded.actor,
    correlation_id = excluded.correlation_id,
    action_key = excluded.action_key,
    payload_json = excluded.payload_json,
    legacy_message = excluded.legacy_message,
    related_urls_json = excluded.related_urls_json";

const INSERT_AUDIT_EVENT_IF_ABSENT_SQL: &str = "
INSERT INTO audit_events (
    id, recorded_at, source, category, kind, severity, outcome, title, summary,
    subject, actor, correlation_id, action_key, payload_json, legacy_message, related_urls_json
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
ON CONFLICT(id) DO NOTHING";

impl AsyncDaemonDb {
    /// Persist one typed application audit event.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or payload serialization failure.
    #[allow(dead_code)]
    pub(crate) async fn upsert_audit_event(
        &self,
        event: &HarnessMonitorAuditEvent,
    ) -> Result<(), CliError> {
        self.write_audit_event(UPSERT_AUDIT_EVENT_SQL, event, "upsert")
            .await
            .map(|_| ())
    }

    pub(crate) async fn insert_audit_event_if_absent(
        &self,
        event: &HarnessMonitorAuditEvent,
    ) -> Result<bool, CliError> {
        self.write_audit_event(INSERT_AUDIT_EVENT_IF_ABSENT_SQL, event, "insert")
            .await
            .map(|rows| rows == 1)
    }

    async fn write_audit_event(
        &self,
        statement: &'static str,
        event: &HarnessMonitorAuditEvent,
        operation: &'static str,
    ) -> Result<u64, CliError> {
        let payload_json = event.payload_json.as_ref().map(Value::to_string);
        let related_urls_json = serde_json::to_string(&event.related_urls)
            .map_err(|error| db_error(format!("serialize audit related urls: {error}")))?;
        query(statement)
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
            .execute(self.pool())
            .await
            .map(|result| result.rows_affected())
            .map_err(|error| db_error(format!("{operation} audit event {}: {error}", event.id)))
    }

    /// Query typed application audit events by time and indexed facets.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or payload decoding failure.
    pub(crate) async fn load_audit_events(
        &self,
        request: &HarnessMonitorAuditEventsRequest,
    ) -> Result<HarnessMonitorAuditEventsResponse, CliError> {
        let limit = request.normalized_limit();
        let mut builder = audit_query_builder(request);
        builder.push(" ORDER BY recorded_at DESC, id DESC LIMIT ");
        builder.push_bind(i64::from(limit) + 1);
        let rows = builder
            .build_query_as::<AuditEventRow>()
            .fetch_all(self.pool())
            .await
            .map_err(|error| db_error(format!("query audit events: {error}")))?;
        audit_response(rows, limit)
    }
}

pub(in crate::daemon::db) async fn upsert_audit_event_in_tx(
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

pub(in crate::daemon::db) async fn insert_audit_event_if_absent_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    event: &HarnessMonitorAuditEvent,
) -> Result<bool, CliError> {
    let payload_json = event.payload_json.as_ref().map(Value::to_string);
    let related_urls_json = serde_json::to_string(&event.related_urls)
        .map_err(|error| db_error(format!("serialize audit related urls: {error}")))?;
    query(INSERT_AUDIT_EVENT_IF_ABSENT_SQL)
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
        .map(|result| result.rows_affected() == 1)
        .map_err(|error| db_error(format!("insert audit event {}: {error}", event.id)))
}

#[derive(Debug, sqlx::FromRow)]
struct AuditEventRow {
    id: String,
    recorded_at: String,
    source: String,
    category: String,
    kind: String,
    severity: String,
    outcome: String,
    title: String,
    summary: String,
    subject: Option<String>,
    actor: Option<String>,
    correlation_id: Option<String>,
    action_key: Option<String>,
    payload_json: Option<String>,
    legacy_message: Option<String>,
    related_urls_json: String,
}

fn audit_query_builder(request: &HarnessMonitorAuditEventsRequest) -> QueryBuilder<Sqlite> {
    let mut builder = QueryBuilder::<Sqlite>::new(AUDIT_SELECT_SQL);
    append_cursor_filter(&mut builder, request.before.as_deref());
    append_date_range_filter(&mut builder, request);
    append_in_filter(&mut builder, "source", &request.sources);
    append_in_filter(&mut builder, "category", &request.categories);
    append_in_filter(&mut builder, "severity", &request.severities);
    append_in_filter(&mut builder, "outcome", &request.outcomes);
    append_in_filter(&mut builder, "action_key", &request.action_keys);
    append_text_filter(&mut builder, "subject", request.subject.as_deref());
    append_search_filter(&mut builder, request.search_text.as_deref());
    builder
}

const AUDIT_SELECT_SQL: &str = "
SELECT id, recorded_at, source, category, kind, severity, outcome, title, summary,
       subject, actor, correlation_id, action_key, payload_json, legacy_message, related_urls_json
FROM audit_events
WHERE 1 = 1";

fn append_cursor_filter(builder: &mut QueryBuilder<Sqlite>, before: Option<&str>) {
    let Some((recorded_at, id)) = before.and_then(|cursor| cursor.split_once('|')) else {
        return;
    };
    builder.push(" AND (recorded_at < ");
    builder.push_bind(recorded_at.to_owned());
    builder.push(" OR (recorded_at = ");
    builder.push_bind(recorded_at.to_owned());
    builder.push(" AND id < ");
    builder.push_bind(id.to_owned());
    builder.push("))");
}

fn append_date_range_filter(
    builder: &mut QueryBuilder<Sqlite>,
    request: &HarnessMonitorAuditEventsRequest,
) {
    if let Some(start) = request
        .date_range
        .as_ref()
        .and_then(|range| range.start.as_ref())
    {
        builder.push(" AND recorded_at >= ");
        builder.push_bind(start);
    }
    if let Some(end) = request
        .date_range
        .as_ref()
        .and_then(|range| range.end.as_ref())
    {
        builder.push(" AND recorded_at <= ");
        builder.push_bind(end);
    }
}

fn append_in_filter(builder: &mut QueryBuilder<Sqlite>, column: &str, values: &[String]) {
    let normalized = normalized_filters(values);
    if normalized.is_empty() {
        return;
    }
    builder.push(" AND ");
    builder.push(column);
    builder.push(" IN (");
    {
        let mut separated = builder.separated(", ");
        for value in normalized {
            separated.push_bind(value);
        }
    }
    builder.push(")");
}

fn append_text_filter(builder: &mut QueryBuilder<Sqlite>, column: &str, value: Option<&str>) {
    let Some(value) = normalized_filter(value) else {
        return;
    };
    builder.push(" AND ");
    builder.push(column);
    builder.push(" = ");
    builder.push_bind(value);
}

fn append_search_filter(builder: &mut QueryBuilder<Sqlite>, value: Option<&str>) {
    let Some(value) = normalized_filter(value) else {
        return;
    };
    let pattern = format!("%{}%", value.replace('%', "\\%").replace('_', "\\_"));
    builder.push(" AND (title LIKE ");
    builder.push_bind(pattern.clone());
    builder.push(" ESCAPE '\\' OR summary LIKE ");
    builder.push_bind(pattern.clone());
    builder.push(" ESCAPE '\\' OR legacy_message LIKE ");
    builder.push_bind(pattern);
    builder.push(" ESCAPE '\\')");
}

fn normalized_filters(values: &[String]) -> Vec<String> {
    values
        .iter()
        .filter_map(|value| normalized_filter(Some(value)))
        .collect()
}

fn normalized_filter(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn audit_response(
    mut rows: Vec<AuditEventRow>,
    limit: u32,
) -> Result<HarnessMonitorAuditEventsResponse, CliError> {
    let has_older = rows.len() > limit as usize;
    if has_older {
        rows.truncate(limit as usize);
    }
    let events = rows
        .into_iter()
        .map(AuditEventRow::into_event)
        .collect::<Result<Vec<_>, _>>()?;
    let next_cursor = has_older.then(|| events.last().map(audit_cursor)).flatten();
    Ok(HarnessMonitorAuditEventsResponse {
        events,
        next_cursor,
        has_older,
    })
}

fn audit_cursor(event: &HarnessMonitorAuditEvent) -> String {
    format!("{}|{}", event.recorded_at, event.id)
}

impl AuditEventRow {
    fn into_event(self) -> Result<HarnessMonitorAuditEvent, CliError> {
        let payload_json = self
            .payload_json
            .map(|payload| serde_json::from_str(&payload))
            .transpose()
            .map_err(|error| db_error(format!("parse audit payload {}: {error}", self.id)))?;
        let related_urls = serde_json::from_str(&self.related_urls_json)
            .map_err(|error| db_error(format!("parse audit related urls {}: {error}", self.id)))?;
        Ok(HarnessMonitorAuditEvent {
            id: self.id,
            recorded_at: self.recorded_at,
            source: self.source,
            category: self.category,
            kind: self.kind,
            severity: self.severity,
            outcome: self.outcome,
            title: self.title,
            summary: self.summary,
            subject: self.subject,
            actor: self.actor,
            correlation_id: self.correlation_id,
            action_key: self.action_key,
            payload_json,
            legacy_message: self.legacy_message,
            related_urls,
        })
    }
}
