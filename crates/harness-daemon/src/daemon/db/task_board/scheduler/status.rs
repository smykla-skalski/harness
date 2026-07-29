use chrono::{DateTime, Duration, Utc};
use sqlx::{Sqlite, SqliteConnection, Transaction, query_as};

mod ledger;
mod queue;
mod targets;
mod wake;

use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::TaskBoardAutomationCancelTarget;
use crate::task_board::{
    TASK_BOARD_AUTOMATION_SNAPSHOT_SCHEMA_VERSION, TaskBoardAutomationAdmissionState,
    TaskBoardAutomationDesiredMode, TaskBoardAutomationEffectiveState,
    TaskBoardAutomationQueueSummary, TaskBoardAutomationRunInfo, TaskBoardAutomationRunOutcome,
    TaskBoardAutomationRunState, TaskBoardAutomationSnapshot,
};

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
    queue: TaskBoardAutomationQueueSummary,
    wake: wake::WakeObservation,
    cancelable_targets: Vec<TaskBoardAutomationCancelTarget>,
    cancelable_targets_truncated: bool,
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
    let ledger = ledger::load(transaction, policy_revision).await?;
    build_snapshot(&ledger, observed_at)
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
        next_run_at: ledger.wake.next_run_at(
            ledger
                .provider_backoff
                .as_ref()
                .map(|backoff| &backoff.earliest),
        ),
        next_retry_at: None,
        last_success_at: facts.last_success.map(|value| value.value),
        last_reconciliation_at: ledger.wake.last_reconciliation_at(),
        settings_revision: ledger.settings_revision,
        policy_revision: ledger.policy_revision,
        queue: ledger.queue.clone(),
        active_run: facts.active_run,
        cancelable_targets: ledger.cancelable_targets.clone(),
        cancelable_targets_truncated: ledger.cancelable_targets_truncated,
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
    ledger.wake.promote_heartbeat(&mut heartbeat_at);
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
    if ledger.wake.is_pending() {
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

fn state(
    effective: TaskBoardAutomationEffectiveState,
    reason: &str,
) -> (TaskBoardAutomationEffectiveState, Option<String>) {
    (effective, Some(reason.to_string()))
}
