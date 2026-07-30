use std::fmt::Display;

use chrono::{DateTime, SecondsFormat, Utc};
use harness_kernel::errors::{CliError, CliErrorKind};

/// Returns the canonical UTC representation of an RFC 3339 timestamp.
///
/// # Errors
/// Returns [`CliError`] when `value` is not a valid RFC 3339 timestamp.
pub fn canonical_time(value: &str) -> Result<String, CliError> {
    parse_time(value).map(|value| value.to_rfc3339_opts(SecondsFormat::AutoSi, true))
}

pub(super) fn parse_time(value: &str) -> Result<DateTime<Utc>, CliError> {
    DateTime::parse_from_rfc3339(value.trim())
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| invalid_transition(format!("invalid workflow timestamp: {error}")))
}

pub(super) fn workflow_error(error: impl Display) -> CliError {
    invalid_transition(error.to_string())
}

pub(super) fn invalid_transition(detail: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(detail.into()).into()
}
