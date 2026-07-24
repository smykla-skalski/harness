use chrono::{DateTime, Utc};

use crate::daemon::db::{CliError, db_error};
use crate::task_board::{TaskBoardAutomationAdmissionState, TaskBoardAutomationDesiredMode};

/// A timestamp kept in both forms: the stored text goes back out on the wire
/// verbatim, while the parsed instant is what comparisons use.
#[derive(Debug, Clone)]
pub(super) struct StoredInstant {
    pub(super) value: String,
    pub(super) instant: DateTime<Utc>,
}

pub(super) fn stored_instant(value: String, context: &str) -> Result<StoredInstant, CliError> {
    let instant = DateTime::parse_from_rfc3339(&value)
        .map_err(|error| db_error(format!("parse task board {context}: {error}")))?
        .with_timezone(&Utc);
    Ok(StoredInstant { value, instant })
}

/// Stands in for a control timestamp that was never written. It only ever
/// seeds [`keep_latest`], so the epoch loses to every real heartbeat.
pub(super) fn unset_instant() -> StoredInstant {
    let instant = DateTime::UNIX_EPOCH;
    StoredInstant {
        value: instant.to_rfc3339(),
        instant,
    }
}

pub(super) fn keep_latest(current: &mut StoredInstant, candidate: StoredInstant) {
    if candidate.instant > current.instant {
        *current = candidate;
    }
}

pub(super) fn nonnegative(value: i64, context: &str) -> Result<u64, CliError> {
    u64::try_from(value).map_err(|error| db_error(format!("parse task board {context}: {error}")))
}

pub(super) fn parse_desired_mode(value: &str) -> Result<TaskBoardAutomationDesiredMode, CliError> {
    match value {
        "off" => Ok(TaskBoardAutomationDesiredMode::Off),
        "continuous" => Ok(TaskBoardAutomationDesiredMode::Continuous),
        "step" => Ok(TaskBoardAutomationDesiredMode::Step),
        value => Err(db_error(format!(
            "invalid task board automation desired mode '{value}'"
        ))),
    }
}

pub(super) fn parse_admission_state(
    value: &str,
) -> Result<TaskBoardAutomationAdmissionState, CliError> {
    match value {
        "accepting" => Ok(TaskBoardAutomationAdmissionState::Accepting),
        "draining" => Ok(TaskBoardAutomationAdmissionState::Draining),
        "stopped" => Ok(TaskBoardAutomationAdmissionState::Stopped),
        value => Err(db_error(format!(
            "invalid task board automation admission state '{value}'"
        ))),
    }
}

pub(super) fn validate_control(
    desired: TaskBoardAutomationDesiredMode,
    admission: TaskBoardAutomationAdmissionState,
) -> Result<(), CliError> {
    use TaskBoardAutomationAdmissionState::{Accepting, Draining, Stopped};
    use TaskBoardAutomationDesiredMode::{Continuous, Off, Step};
    match (desired, admission) {
        (Off, Stopped | Draining) | (Continuous | Step, Accepting) => Ok(()),
        _ => Err(db_error("incoherent task board automation control state")),
    }
}
