use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::Response;

use crate::daemon::protocol::{
    HarnessMonitorAuditDateRange, HarnessMonitorAuditEventsRequest, http_paths,
};

use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};
use super::{DaemonHttpState, require_async_db};

#[derive(Debug, Default, serde::Deserialize)]
pub(crate) struct AuditEventsQuery {
    limit: Option<u32>,
    before: Option<String>,
    date_range_start: Option<String>,
    date_range_end: Option<String>,
    sources: Option<String>,
    categories: Option<String>,
    severities: Option<String>,
    outcomes: Option<String>,
    action_keys: Option<String>,
    subject: Option<String>,
    search_text: Option<String>,
}

impl AuditEventsQuery {
    fn into_request(self) -> HarnessMonitorAuditEventsRequest {
        HarnessMonitorAuditEventsRequest {
            limit: self.limit,
            before: self.before,
            date_range: date_range(self.date_range_start, self.date_range_end),
            sources: csv_values(self.sources),
            categories: csv_values(self.categories),
            severities: csv_values(self.severities),
            outcomes: csv_values(self.outcomes),
            action_keys: csv_values(self.action_keys),
            subject: self.subject,
            search_text: self.search_text,
        }
    }
}

pub(super) async fn get_audit_events(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Query(query): Query<AuditEventsQuery>,
) -> Response {
    let start = std::time::Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let request = query.into_request();
    let result = match require_async_db(&state, "audit events") {
        Ok(db) => db.load_audit_events(&request).await,
        Err(error) => Err(error),
    };
    timed_json("GET", http_paths::AUDIT_EVENTS, &request_id, start, result)
}

fn date_range(start: Option<String>, end: Option<String>) -> Option<HarnessMonitorAuditDateRange> {
    let range = HarnessMonitorAuditDateRange { start, end };
    (range.start.is_some() || range.end.is_some()).then_some(range)
}

fn csv_values(values: Option<String>) -> Vec<String> {
    values
        .into_iter()
        .flat_map(|values| {
            values
                .split(',')
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .collect()
}
