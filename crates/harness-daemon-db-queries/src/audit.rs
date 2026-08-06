use harness_daemon_db_core::{AsyncDaemonDb, db_error};
use harness_kernel::errors::CliError;
use harness_protocol::daemon::audit::{
    HarnessMonitorAuditEvent, HarnessMonitorAuditEventsRequest, HarnessMonitorAuditEventsResponse,
};
use sqlx::{QueryBuilder, Sqlite};

/// Read-side audit query surface, kept as its own trait (instead of folding
/// into `AuditEventStore`) since that one is deliberately scoped to only the
/// two write operations the recorder calls.
pub trait AsyncAuditQueries: Send + Sync {
    /// # Errors
    /// Returns [`CliError`] on SQL or payload decoding failure.
    fn load_audit_events(
        &self,
        request: &HarnessMonitorAuditEventsRequest,
    ) -> impl std::future::Future<Output = Result<HarnessMonitorAuditEventsResponse, CliError>> + Send;
}

impl AsyncAuditQueries for AsyncDaemonDb {
    async fn load_audit_events(
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
