use chrono::Duration;
use sqlx::{Sqlite, SqliteConnection, Transaction, query_as};

use super::super::super::ORCHESTRATOR_CHANGE_SCOPE;
use super::{ControlObservation, ProviderBackoff, SnapshotLedger, nonnegative, stored_instant};
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    TaskBoardAutomationAdmissionState, TaskBoardAutomationDesiredMode, TaskBoardAutomationRunInfo,
    TaskBoardOrchestratorSettings,
};

const MINIMUM_OFFLINE_AFTER_SECONDS: i64 = 30;
const OFFLINE_RECONCILIATION_MULTIPLIER: u64 = 3;

#[derive(sqlx::FromRow)]
struct ProviderBackoffRow {
    row_count: i64,
    deadline_count: i64,
    minimum_failure_count: Option<i64>,
    earliest_deadline: Option<String>,
    latest_deadline: Option<String>,
}

struct ControlLedger {
    revision: u64,
    settings_revision: u64,
    offline_after: Duration,
    control: ControlObservation,
}

struct ActivityLedger {
    runs: Vec<TaskBoardAutomationRunInfo>,
    provider_backoff: Option<ProviderBackoff>,
    open_conflict: bool,
    queue: crate::task_board::TaskBoardAutomationQueueSummary,
    wake: super::wake::WakeObservation,
}

pub(super) async fn load(
    transaction: &mut Transaction<'_, Sqlite>,
    policy_revision: u64,
) -> Result<SnapshotLedger, CliError> {
    let connection = transaction.as_mut();
    let control = load_control_ledger(connection).await?;
    let activity = load_activity_ledger(connection).await?;
    let targets = super::targets::load(transaction).await?;
    Ok(SnapshotLedger {
        revision: control.revision,
        settings_revision: control.settings_revision,
        policy_revision,
        offline_after: control.offline_after,
        control: control.control,
        runs: activity.runs,
        provider_backoff: activity.provider_backoff,
        open_conflict: activity.open_conflict,
        queue: activity.queue,
        wake: activity.wake,
        cancelable_targets: targets.targets,
        cancelable_targets_truncated: targets.truncated,
    })
}

async fn load_control_ledger(connection: &mut SqliteConnection) -> Result<ControlLedger, CliError> {
    let (settings_revision, offline_after) = load_settings(connection).await?;
    let control = load_control(connection).await?;
    Ok(ControlLedger {
        revision: load_revision(connection).await?,
        settings_revision,
        offline_after,
        control,
    })
}

async fn load_activity_ledger(
    connection: &mut SqliteConnection,
) -> Result<ActivityLedger, CliError> {
    Ok(ActivityLedger {
        runs: super::super::history::load_snapshot_run_infos(connection).await?,
        provider_backoff: load_provider_backoff(connection).await?,
        open_conflict: load_open_conflict(connection).await?,
        queue: super::queue::load(connection).await?,
        wake: super::wake::load(connection).await?,
    })
}

async fn load_revision(connection: &mut SqliteConnection) -> Result<u64, CliError> {
    let row = query_as::<_, (i64,)>("SELECT change_seq FROM change_tracking WHERE scope = ?1")
        .bind(ORCHESTRATOR_CHANGE_SCOPE)
        .fetch_optional(&mut *connection)
        .await
        .map_err(|error| db_error(format!("load task board automation revision: {error}")))?;
    nonnegative(row.map_or(0, |row| row.0), "automation revision")
}

async fn load_settings(connection: &mut SqliteConnection) -> Result<(u64, Duration), CliError> {
    let row = query_as::<_, (String, i64)>(
        "SELECT settings_json, revision
         FROM task_board_orchestrator_settings WHERE singleton = 1",
    )
    .fetch_optional(&mut *connection)
    .await
    .map_err(|error| db_error(format!("load task board automation settings: {error}")))?;
    let (settings, revision) = row.map_or_else(
        || Ok((TaskBoardOrchestratorSettings::default(), 0)),
        |(settings, revision)| {
            serde_json::from_str::<TaskBoardOrchestratorSettings>(&settings)
                .map(|settings| (settings, revision))
                .map_err(|error| db_error(format!("parse task board automation settings: {error}")))
        },
    )?;
    let offline_seconds = settings
        .scheduling
        .reconcile_interval_seconds
        .saturating_mul(OFFLINE_RECONCILIATION_MULTIPLIER);
    let offline_seconds = i64::try_from(offline_seconds)
        .unwrap_or(i64::MAX)
        .max(MINIMUM_OFFLINE_AFTER_SECONDS);
    let offline_after = Duration::try_seconds(offline_seconds)
        .ok_or_else(|| db_error("task board automation offline threshold is out of range"))?;
    Ok((nonnegative(revision, "settings revision")?, offline_after))
}

async fn load_control(connection: &mut SqliteConnection) -> Result<ControlObservation, CliError> {
    let row = query_as::<_, (String, String, String)>(
        "SELECT desired_mode, admission_state, updated_at
         FROM task_board_orchestrator_control WHERE singleton = 1",
    )
    .fetch_optional(&mut *connection)
    .await
    .map_err(|error| {
        db_error(format!(
            "load task board automation snapshot control: {error}"
        ))
    })?
    .ok_or_else(|| db_error("task board automation control is not initialized"))?;
    let desired_mode = parse_desired_mode(&row.0)?;
    let admission_state = parse_admission_state(&row.1)?;
    validate_control(desired_mode, admission_state)?;
    Ok(ControlObservation {
        desired_mode,
        admission_state,
        updated_at: stored_instant(row.2, "automation control timestamp")?,
    })
}

async fn load_provider_backoff(
    connection: &mut SqliteConnection,
) -> Result<Option<ProviderBackoff>, CliError> {
    let row = query_as::<_, ProviderBackoffRow>(
        "SELECT COUNT(*) AS row_count, COUNT(backoff_until) AS deadline_count,
                MIN(failure_count) AS minimum_failure_count,
                MIN(backoff_until) AS earliest_deadline,
                MAX(backoff_until) AS latest_deadline
         FROM task_board_provider_scope_state WHERE health = 'backing_off'",
    )
    .fetch_one(&mut *connection)
    .await
    .map_err(|error| db_error(format!("load task board provider backoff: {error}")))?;
    decode_provider_backoff(row)
}

fn decode_provider_backoff(row: ProviderBackoffRow) -> Result<Option<ProviderBackoff>, CliError> {
    if row.row_count == 0 {
        return Ok(None);
    }
    if row.deadline_count != row.row_count
        || row.minimum_failure_count.is_none_or(|value| value <= 0)
    {
        return Err(db_error("incoherent task board provider backoff state"));
    }
    let earliest = row
        .earliest_deadline
        .ok_or_else(|| db_error("task board provider backoff has no earliest deadline"))?;
    let latest = row
        .latest_deadline
        .ok_or_else(|| db_error("task board provider backoff has no latest deadline"))?;
    Ok(Some(ProviderBackoff {
        earliest: stored_instant(earliest, "provider backoff deadline")?,
        latest: stored_instant(latest, "provider backoff deadline")?,
    }))
}

async fn load_open_conflict(connection: &mut SqliteConnection) -> Result<bool, CliError> {
    let (open,) = query_as::<_, (i64,)>(
        "SELECT EXISTS(
            SELECT 1 FROM task_board_sync_conflicts WHERE state = 'open' LIMIT 1
         )",
    )
    .fetch_one(&mut *connection)
    .await
    .map_err(|error| db_error(format!("load open task board sync conflict: {error}")))?;
    match open {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(db_error("invalid task board sync conflict existence value")),
    }
}

fn parse_desired_mode(value: &str) -> Result<TaskBoardAutomationDesiredMode, CliError> {
    match value {
        "off" => Ok(TaskBoardAutomationDesiredMode::Off),
        "continuous" => Ok(TaskBoardAutomationDesiredMode::Continuous),
        "step" => Ok(TaskBoardAutomationDesiredMode::Step),
        value => Err(db_error(format!(
            "invalid task board automation desired mode '{value}'"
        ))),
    }
}

fn parse_admission_state(value: &str) -> Result<TaskBoardAutomationAdmissionState, CliError> {
    match value {
        "accepting" => Ok(TaskBoardAutomationAdmissionState::Accepting),
        "draining" => Ok(TaskBoardAutomationAdmissionState::Draining),
        "stopped" => Ok(TaskBoardAutomationAdmissionState::Stopped),
        value => Err(db_error(format!(
            "invalid task board automation admission state '{value}'"
        ))),
    }
}

fn validate_control(
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
