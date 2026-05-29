use chrono::{DateTime, Duration, Utc};

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::policy_graph::PolicyWaitCondition;

use super::models::{PolicyRunStatus, PolicyWorkflowRun};

#[must_use]
pub fn is_timer_waiting(run: &PolicyWorkflowRun) -> bool {
    run.status == PolicyRunStatus::Waiting
        && matches!(run.waiting_on, Some(PolicyWaitCondition::Timer { .. }))
}

pub fn timer_wait_due_at(run: &PolicyWorkflowRun) -> Result<Option<DateTime<Utc>>, CliError> {
    let Some(PolicyWaitCondition::Timer { duration_seconds }) = run.waiting_on.as_ref() else {
        return Ok(None);
    };
    // Anchor the deadline to when the wait began, falling back to
    // `updated_at` only for runs persisted before `waiting_since` existed.
    // A manual nudge bumps `updated_at` but never `waiting_since`, so it
    // cannot extend a pending timer.
    let waited_at_raw = run.waiting_since.as_deref().unwrap_or(&run.updated_at);
    let waited_at = DateTime::parse_from_rfc3339(waited_at_raw)
        .map_err(|error| {
            CliErrorKind::workflow_parse(format!(
                "policy workflow run '{}' has invalid wait timestamp '{}': {error}",
                run.run_id, waited_at_raw
            ))
        })?
        .with_timezone(&Utc);
    let duration_seconds = i64::try_from(*duration_seconds).map_err(|_| {
        CliErrorKind::workflow_parse(format!(
            "policy workflow run '{}' timer wait exceeds supported duration: {duration_seconds}",
            run.run_id
        ))
    })?;
    let wait_duration = Duration::try_seconds(duration_seconds).ok_or_else(|| {
        CliErrorKind::workflow_parse(format!(
            "policy workflow run '{}' timer wait exceeds supported duration: {duration_seconds}",
            run.run_id
        ))
    })?;
    Ok(Some(waited_at + wait_duration))
}

pub fn timer_wait_is_due(run: &PolicyWorkflowRun, now: &DateTime<Utc>) -> Result<bool, CliError> {
    if !is_timer_waiting(run) {
        return Ok(false);
    }
    Ok(timer_wait_due_at(run)?.is_some_and(|due_at| due_at <= now.to_owned()))
}
