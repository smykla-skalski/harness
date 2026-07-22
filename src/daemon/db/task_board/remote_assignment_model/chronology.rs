use chrono::{DateTime, Utc};

use super::{RemoteAssignmentRow, canonical_time};
use crate::daemon::db::{CliError, db_error};

pub(super) fn validate_persisted_chronology(row: &RemoteAssignmentRow) -> Result<(), CliError> {
    canonical_time(&row.offered_at, "durable remote assignment offer time")?;
    canonical_time(&row.updated_at, "durable remote assignment update time")?;
    let claimed = optional_canonical_time(
        row.claimed_at.as_deref(),
        "durable remote assignment claim time",
    )?;
    let started = optional_canonical_time(
        row.started_at.as_deref(),
        "durable remote assignment start time",
    )?;
    for (value, field) in [
        (
            row.heartbeat_at.as_deref(),
            "durable remote assignment heartbeat time",
        ),
        (
            row.lease_expires_at.as_deref(),
            "durable remote assignment lease expiry",
        ),
        (
            row.deadline_at.as_deref(),
            "durable remote assignment deadline",
        ),
        (
            row.cancel_requested_at.as_deref(),
            "durable remote assignment cancel time",
        ),
        (
            row.completed_at.as_deref(),
            "durable remote assignment completion time",
        ),
        (
            row.cleanup_completed_at.as_deref(),
            "durable remote assignment cleanup time",
        ),
    ] {
        optional_canonical_time(value, field)?;
    }
    if claimed
        .zip(started)
        .is_some_and(|(claim, start)| start < claim)
    {
        return Err(db_error(
            "durable remote assignment start time precedes claim time",
        ));
    }
    Ok(())
}

fn optional_canonical_time(
    value: Option<&str>,
    field: &str,
) -> Result<Option<DateTime<Utc>>, CliError> {
    value.map(|value| canonical_time(value, field)).transpose()
}
