use chrono::{DateTime, Duration, Utc};
use sqlx::{Sqlite, SqliteConnection, Transaction, query_as};

use super::super::ORCHESTRATOR_CHANGE_SCOPE;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::{
    TASK_BOARD_AUTOMATION_SNAPSHOT_SCHEMA_VERSION, TaskBoardAutomationAdmissionState,
    TaskBoardAutomationDesiredMode, TaskBoardAutomationEffectiveState,
    TaskBoardAutomationQueueSummary, TaskBoardAutomationRunInfo, TaskBoardAutomationRunOutcome,
    TaskBoardAutomationRunState, TaskBoardAutomationSnapshot, TaskBoardOrchestratorSettings,
};

const MINIMUM_OFFLINE_AFTER_SECONDS: i64 = 30;
const OFFLINE_RECONCILIATION_MULTIPLIER: u64 = 3;

#[derive(Debug)]
struct SnapshotLedger {
    revision: u64,
    settings_revision: u64,
    policy_revision: u64,
    offline_after: Duration,
    control: ControlObservation,
    runs: Vec<TaskBoardAutomationRunInfo>,
    provider_backoff: Option<ProviderBackoff>,
    open_conflict: bool,
}

struct SnapshotActivity {
    revision: u64,
    runs: Vec<TaskBoardAutomationRunInfo>,
    provider_backoff: Option<ProviderBackoff>,
    open_conflict: bool,
}

#[derive(sqlx::FromRow)]
struct ActivePolicyRow {
    enforcement_enabled: i64,
    mode: Option<String>,
    draft_revision: Option<i64>,
    has_live: i64,
    live_revision: Option<String>,
}

#[derive(Debug)]
struct ControlObservation {
    desired_mode: TaskBoardAutomationDesiredMode,
    admission_state: TaskBoardAutomationAdmissionState,
    updated_at: StoredInstant,
}

#[derive(Debug, Clone)]
struct StoredInstant {
    value: String,
    instant: DateTime<Utc>,
}

#[derive(Debug)]
struct ProviderBackoff {
    earliest: StoredInstant,
    latest: StoredInstant,
}

#[derive(sqlx::FromRow)]
struct ProviderBackoffRow {
    row_count: i64,
    deadline_count: i64,
    minimum_failure_count: Option<i64>,
    earliest_deadline: Option<String>,
    latest_deadline: Option<String>,
}

impl AsyncDaemonDb {
    pub(crate) async fn task_board_automation_snapshot(
        &self,
    ) -> Result<TaskBoardAutomationSnapshot, CliError> {
        let mut transaction = self.pool().begin().await.map_err(|error| {
            db_error(format!(
                "begin task board automation snapshot transaction: {error}"
            ))
        })?;
        let snapshot = snapshot_in_transaction(&mut transaction).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit task board automation snapshot transaction: {error}"
            ))
        })?;
        Ok(snapshot)
    }
}

pub(super) async fn snapshot_in_transaction(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<TaskBoardAutomationSnapshot, CliError> {
    let (policy_revision, observed_at) = begin_snapshot_observation(transaction.as_mut()).await?;
    snapshot_after_observation(transaction, policy_revision, observed_at).await
}

pub(super) async fn begin_snapshot_observation(
    connection: &mut SqliteConnection,
) -> Result<(u64, DateTime<Utc>), CliError> {
    let policy_revision = load_active_policy_revision(connection).await?;
    Ok((policy_revision, Utc::now()))
}

pub(super) async fn snapshot_after_observation(
    transaction: &mut Transaction<'_, Sqlite>,
    policy_revision: u64,
    observed_at: DateTime<Utc>,
) -> Result<TaskBoardAutomationSnapshot, CliError> {
    let ledger = load_snapshot_ledger(transaction.as_mut(), policy_revision).await?;
    build_snapshot(&ledger, observed_at)
}

async fn load_snapshot_ledger(
    connection: &mut SqliteConnection,
    policy_revision: u64,
) -> Result<SnapshotLedger, CliError> {
    let (settings_revision, offline_after) = load_settings(connection).await?;
    let control = load_control(connection).await?;
    let activity = load_snapshot_activity(connection).await?;
    Ok(SnapshotLedger {
        revision: activity.revision,
        settings_revision,
        policy_revision,
        offline_after,
        control,
        runs: activity.runs,
        provider_backoff: activity.provider_backoff,
        open_conflict: activity.open_conflict,
    })
}

async fn load_snapshot_activity(
    connection: &mut SqliteConnection,
) -> Result<SnapshotActivity, CliError> {
    Ok(SnapshotActivity {
        revision: load_revision(connection).await?,
        runs: super::history::load_snapshot_run_infos(connection).await?,
        provider_backoff: load_provider_backoff(connection).await?,
        open_conflict: load_open_conflict(connection).await?,
    })
}

async fn load_active_policy_revision(connection: &mut SqliteConnection) -> Result<u64, CliError> {
    let row = query_as::<_, ActivePolicyRow>(
        "SELECT w.global_policy_enforcement_enabled AS enforcement_enabled,
                c.mode, c.revision AS draft_revision,
                CASE WHEN c.live_document_json IS NULL THEN 0 ELSE 1 END AS has_live,
                CASE WHEN c.live_document_json IS NULL THEN NULL
                     WHEN json_type(c.live_document_json, '$.revision') = 'integer'
                     THEN CAST(json_extract(c.live_document_json, '$.revision') AS TEXT)
                END AS live_revision
         FROM policy_workspace AS w
         LEFT JOIN policy_canvases AS c ON c.canvas_id = w.active_canvas_id
         WHERE w.singleton = 1",
    )
    .fetch_optional(&mut *connection)
    .await
    .map_err(|error| db_error(format!("load active task board policy revision: {error}")))?;
    active_policy_revision(row)
}

fn active_policy_revision(row: Option<ActivePolicyRow>) -> Result<u64, CliError> {
    let Some(row) = row else {
        return Ok(0);
    };
    if row.enforcement_enabled == 0 {
        return Ok(0);
    }
    if row.enforcement_enabled != 1 {
        return Err(db_error("invalid task board policy enforcement value"));
    }
    if row.has_live == 1 {
        let revision = row
            .live_revision
            .ok_or_else(|| db_error("active task board live policy has no integer revision"))?;
        return revision.parse::<u64>().map_err(|error| {
            db_error(format!(
                "parse active task board live policy revision: {error}"
            ))
        });
    }
    if row.has_live != 0 {
        return Err(db_error("invalid task board live policy existence value"));
    }
    match (row.mode.as_deref(), row.draft_revision) {
        (Some("enforced"), Some(revision)) => nonnegative(revision, "active policy revision"),
        _ => Ok(0),
    }
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

fn build_snapshot(
    ledger: &SnapshotLedger,
    observed_at: DateTime<Utc>,
) -> Result<TaskBoardAutomationSnapshot, CliError> {
    let facts = run_facts(ledger)?;
    let heartbeat_age = observed_at.signed_duration_since(facts.heartbeat_at.instant);
    if heartbeat_age < Duration::zero() {
        return Err(db_error("task board automation heartbeat is in the future"));
    }
    let offline = ledger.control.desired_mode == TaskBoardAutomationDesiredMode::Continuous
        && ledger.control.admission_state == TaskBoardAutomationAdmissionState::Accepting
        && heartbeat_age > ledger.offline_after;
    let (effective_state, blocked_reason) =
        derive_effective_state(ledger, &facts, observed_at, offline);
    Ok(TaskBoardAutomationSnapshot {
        schema_version: TASK_BOARD_AUTOMATION_SNAPSHOT_SCHEMA_VERSION,
        revision: ledger.revision,
        desired_mode: ledger.control.desired_mode,
        admission_state: ledger.control.admission_state,
        effective_state,
        observed_at: observed_at.to_rfc3339(),
        heartbeat_at: facts.heartbeat_at.value,
        heartbeat_age_seconds: Some(u64::try_from(heartbeat_age.num_seconds()).unwrap_or(u64::MAX)),
        next_run_at: ledger
            .provider_backoff
            .as_ref()
            .map(|backoff| backoff.earliest.value.clone()),
        next_retry_at: None,
        last_success_at: facts.last_success.map(|value| value.value),
        last_reconciliation_at: None,
        settings_revision: ledger.settings_revision,
        policy_revision: ledger.policy_revision,
        queue: TaskBoardAutomationQueueSummary::default(),
        active_run: facts.active_run,
        blocked_reason,
    })
}

struct RunFacts {
    active_run: Option<TaskBoardAutomationRunInfo>,
    heartbeat_at: StoredInstant,
    last_success: Option<StoredInstant>,
    latest_terminal_failed: bool,
    cancelling: bool,
}

fn run_facts(ledger: &SnapshotLedger) -> Result<RunFacts, CliError> {
    let mut active = Vec::new();
    let mut heartbeat_at = ledger.control.updated_at.clone();
    let mut last_success = None::<StoredInstant>;
    let mut latest_terminal = None::<(StoredInstant, String, TaskBoardAutomationRunOutcome)>;
    for run in &ledger.runs {
        let heartbeat = stored_instant(run.heartbeat_at.clone(), "automation run heartbeat")?;
        keep_latest(&mut heartbeat_at, heartbeat);
        if matches!(
            run.state,
            TaskBoardAutomationRunState::Running | TaskBoardAutomationRunState::Cancelling
        ) {
            active.push(run.clone());
        }
        let Some(completed_at) = run.completed_at.as_ref() else {
            continue;
        };
        let completed = stored_instant(completed_at.clone(), "automation run completion")?;
        let outcome = run
            .outcome
            .ok_or_else(|| db_error("terminal automation run has no outcome"))?;
        if matches!(
            outcome,
            TaskBoardAutomationRunOutcome::Completed | TaskBoardAutomationRunOutcome::Noop
        ) && last_success
            .as_ref()
            .is_none_or(|current| completed.instant > current.instant)
        {
            last_success = Some(completed.clone());
        }
        if latest_terminal.as_ref().is_none_or(|current| {
            (completed.instant, run.run_id.as_str()) > (current.0.instant, current.1.as_str())
        }) {
            latest_terminal = Some((completed, run.run_id.clone(), outcome));
        }
    }
    if active.len() > 1 {
        return Err(db_error("multiple active task board automation runs"));
    }
    let cancelling = active
        .first()
        .is_some_and(|run| run.state == TaskBoardAutomationRunState::Cancelling);
    Ok(RunFacts {
        active_run: active.pop(),
        heartbeat_at,
        last_success,
        latest_terminal_failed: latest_terminal
            .is_some_and(|(_, _, outcome)| outcome == TaskBoardAutomationRunOutcome::Failed),
        cancelling,
    })
}

fn derive_effective_state(
    ledger: &SnapshotLedger,
    facts: &RunFacts,
    observed_at: DateTime<Utc>,
    offline: bool,
) -> (TaskBoardAutomationEffectiveState, Option<String>) {
    if ledger.control.admission_state == TaskBoardAutomationAdmissionState::Draining
        || facts.cancelling
    {
        return state(
            TaskBoardAutomationEffectiveState::Stopping,
            "automation_draining",
        );
    }
    if ledger.control.admission_state == TaskBoardAutomationAdmissionState::Stopped {
        return (TaskBoardAutomationEffectiveState::Idle, None);
    }
    if offline {
        return state(
            TaskBoardAutomationEffectiveState::Offline,
            "coordinator_heartbeat_stale",
        );
    }
    if facts.active_run.is_some() {
        return (TaskBoardAutomationEffectiveState::Running, None);
    }
    if ledger.open_conflict {
        return state(
            TaskBoardAutomationEffectiveState::Degraded,
            "open_sync_conflict",
        );
    }
    if facts.latest_terminal_failed {
        return state(
            TaskBoardAutomationEffectiveState::Degraded,
            "last_run_failed",
        );
    }
    if let Some(backoff) = ledger.provider_backoff.as_ref() {
        if backoff.latest.instant > observed_at {
            return state(
                TaskBoardAutomationEffectiveState::BackingOff,
                "provider_backoff",
            );
        }
        return (TaskBoardAutomationEffectiveState::Scheduled, None);
    }
    (TaskBoardAutomationEffectiveState::Idle, None)
}

fn stored_instant(value: String, context: &str) -> Result<StoredInstant, CliError> {
    let instant = DateTime::parse_from_rfc3339(&value)
        .map_err(|error| db_error(format!("parse task board {context}: {error}")))?
        .with_timezone(&Utc);
    Ok(StoredInstant { value, instant })
}

fn keep_latest(current: &mut StoredInstant, candidate: StoredInstant) {
    if candidate.instant > current.instant {
        *current = candidate;
    }
}

fn nonnegative(value: i64, context: &str) -> Result<u64, CliError> {
    u64::try_from(value).map_err(|error| db_error(format!("parse task board {context}: {error}")))
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

fn state(
    effective: TaskBoardAutomationEffectiveState,
    reason: &str,
) -> (TaskBoardAutomationEffectiveState, Option<String>) {
    (effective, Some(reason.to_string()))
}
