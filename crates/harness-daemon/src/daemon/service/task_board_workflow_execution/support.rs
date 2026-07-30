use std::fmt::Display;

use chrono::{DateTime, SecondsFormat, Utc};
use harness_kernel::errors::{CliError, CliErrorKind};

pub(crate) fn canonical_time(value: &str) -> Result<String, CliError> {
    parse_time(value).map(|value| value.to_rfc3339_opts(SecondsFormat::AutoSi, true))
}

pub(super) fn parse_time(value: &str) -> Result<DateTime<Utc>, CliError> {
    DateTime::parse_from_rfc3339(value.trim())
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| invalid_transition(format!("invalid workflow timestamp: {error}")))
}

#[cfg(test)]
pub(super) fn required(value: &str, field: &str) -> Result<String, CliError> {
    let value = value.trim();
    if value.is_empty() {
        Err(invalid_transition(format!("{field} is empty")))
    } else {
        Ok(value.to_owned())
    }
}

pub(super) fn workflow_error(error: impl Display) -> CliError {
    invalid_transition(error.to_string())
}

pub(super) fn invalid_transition(detail: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(detail.into()).into()
}
