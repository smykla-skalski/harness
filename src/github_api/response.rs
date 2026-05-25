use reqwest::StatusCode;
use serde_json::{Value, json};

use crate::errors::{CliError, CliErrorKind};

use super::budget::GitHubRateLimitSnapshot;
use super::cache::GitHubCacheState;
use super::types::{GitHubResponseCacheState, GitHubResponseProvenance};

pub(crate) struct GitHubApiResponse<T> {
    pub(crate) body: T,
    pub(crate) provenance: GitHubResponseProvenance,
    pub(crate) status_code: Option<u16>,
}

pub(super) fn graphql_data(
    value: &Value,
    provenance: &GitHubResponseProvenance,
) -> Result<Value, CliError> {
    ensure_graphql_ok(value, provenance)?;
    value
        .get("data")
        .cloned()
        .ok_or_else(|| CliErrorKind::workflow_parse("github graphql response missing data").into())
}

pub(super) fn ensure_graphql_ok(
    value: &Value,
    provenance: &GitHubResponseProvenance,
) -> Result<(), CliError> {
    if provenance.from_cache {
        return Ok(());
    }
    let Some(errors) = value.get("errors").and_then(Value::as_array) else {
        return Ok(());
    };
    if errors.is_empty() {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!("GitHub GraphQL error: {}", errors[0])).into())
}

pub(super) fn revalidated_response(
    body: Value,
    snapshot: Option<GitHubRateLimitSnapshot>,
) -> GitHubApiResponse<Value> {
    GitHubApiResponse {
        body,
        provenance: GitHubResponseProvenance {
            from_cache: true,
            cache_age_seconds: Some(0),
            cache_state: GitHubResponseCacheState::Revalidated,
            rate_limit_snapshot: snapshot,
        },
        status_code: Some(StatusCode::NOT_MODIFIED.as_u16()),
    }
}

pub(super) fn cache_state(state: GitHubCacheState, deferred: bool) -> GitHubResponseCacheState {
    if deferred {
        return GitHubResponseCacheState::Deferred;
    }
    match state {
        GitHubCacheState::Fresh => GitHubResponseCacheState::Fresh,
        GitHubCacheState::Stale => GitHubResponseCacheState::Stale,
    }
}

pub(super) fn provenance_with_snapshot(
    mut provenance: GitHubResponseProvenance,
    snapshot: Option<GitHubRateLimitSnapshot>,
) -> GitHubResponseProvenance {
    if let Some(snapshot) = snapshot {
        provenance.rate_limit_snapshot = Some(snapshot);
    }
    provenance
}

pub(super) fn value_u32(value: Option<&Value>) -> Option<u32> {
    value
        .and_then(Value::as_u64)
        .and_then(|value| u32::try_from(value).ok())
}

pub(super) fn request_error(operation: &str, error: reqwest::Error) -> CliError {
    CliErrorKind::workflow_io(format!("{operation}: github request failed: {error}")).into()
}

pub(super) fn context_error(operation: &str, error: CliError) -> CliError {
    let mut wrapped: CliError =
        CliErrorKind::workflow_io(format!("{operation}: {}", error.message())).into();
    if let Some(details) = error.details() {
        wrapped = wrapped.with_details(details);
    }
    wrapped
}

pub(super) fn budget_error(operation: &str, error: super::GitHubBudgetError) -> CliError {
    CliErrorKind::workflow_io(format!(
        "{operation}: github {:?} budget cooling for {}s ({})",
        error.resource,
        error.retry_after.as_secs(),
        error.reason
    ))
    .into()
}

pub(super) fn http_status_error(status: StatusCode, body: &str) -> CliError {
    let parsed: Value = serde_json::from_str(body).unwrap_or_else(|_| json!({ "message": body }));
    let message = parsed
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("GitHub request failed");
    CliError::new(CliErrorKind::workflow_io(format!(
        "GitHub API returned {status}: {message}"
    )))
    .with_details(body.to_string())
}
