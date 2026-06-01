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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audit_events_query_maps_http_params_to_shared_request() {
        let request = AuditEventsQuery {
            limit: Some(25),
            before: Some("2026-06-01T10:00:00Z|event-2".into()),
            date_range_start: Some("2026-06-01T00:00:00Z".into()),
            date_range_end: Some("2026-06-02T00:00:00Z".into()),
            sources: Some(" github, daemon ,, ".into()),
            categories: Some("githubMutation,policy".into()),
            severities: Some("error, warning".into()),
            outcomes: Some("failure,success".into()),
            action_keys: Some("reviews.merge,reviews.approve".into()),
            subject: Some("kong/kuma#12".into()),
            search_text: Some("conflict".into()),
        }
        .into_request();

        assert_eq!(request.limit, Some(25));
        assert_eq!(
            request.before.as_deref(),
            Some("2026-06-01T10:00:00Z|event-2")
        );
        assert_eq!(
            request.date_range,
            Some(HarnessMonitorAuditDateRange {
                start: Some("2026-06-01T00:00:00Z".into()),
                end: Some("2026-06-02T00:00:00Z".into()),
            })
        );
        assert_eq!(request.sources, vec!["github", "daemon"]);
        assert_eq!(request.categories, vec!["githubMutation", "policy"]);
        assert_eq!(request.severities, vec!["error", "warning"]);
        assert_eq!(request.outcomes, vec!["failure", "success"]);
        assert_eq!(
            request.action_keys,
            vec!["reviews.merge", "reviews.approve"]
        );
        assert_eq!(request.subject.as_deref(), Some("kong/kuma#12"));
        assert_eq!(request.search_text.as_deref(), Some("conflict"));
    }

    #[test]
    fn audit_events_query_omits_empty_date_range_and_csv_filters() {
        let request = AuditEventsQuery {
            sources: Some(" , , ".into()),
            categories: Some(String::new()),
            ..AuditEventsQuery::default()
        }
        .into_request();

        assert!(request.date_range.is_none());
        assert!(request.sources.is_empty());
        assert!(request.categories.is_empty());
    }
}
