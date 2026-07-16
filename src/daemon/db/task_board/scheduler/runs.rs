use chrono::{DateTime, Duration, Utc};
use serde_json::json;
use sqlx::{Sqlite, Transaction, query, query_as};

use super::super::ORCHESTRATOR_CHANGE_SCOPE;
use super::super::items::bump_change_in_tx;
use super::audit::{
    broadcast_automation_audits, insert_automation_audit, parse_scope, terminal_event_type,
};
use super::control::{TaskBoardAutomationControlRecord, ensure_control_row, load_control_in_tx};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::protocol::HarnessMonitorAuditEvent;
use crate::task_board::{
    TaskBoardAutomationAdmissionState, TaskBoardAutomationDesiredMode,
    TaskBoardAutomationRunOutcome, TaskBoardAutomationRunTrigger, TaskBoardAutomationScope,
};

const RUN_LEASE_SECONDS: i64 = 30;

#[derive(Debug, Clone)]
pub(crate) struct TaskBoardRunAcquireRequest {
    pub(crate) run_id: String,
    pub(crate) trigger: TaskBoardAutomationRunTrigger,
    pub(crate) actor: Option<String>,
    pub(crate) dry_run: bool,
    pub(crate) scope: TaskBoardAutomationScope,
    pub(crate) lease_owner: String,
    pub(crate) now: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardAutomationRunLease {
    pub(crate) run_id: String,
    pub(crate) trigger: TaskBoardAutomationRunTrigger,
    pub(crate) lease_owner: String,
    pub(crate) lease_epoch: u64,
    pub(crate) stop_generation: u64,
    pub(crate) started_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TaskBoardAutomationRunAdmission {
    Acquired(TaskBoardAutomationRunLease),
    Busy { run_id: String },
    Disabled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TaskBoardAutomationRunFence {
    Active,
    Draining,
}

struct RunFenceRow {
    state: String,
    lease_expires_at: DateTime<Utc>,
    scope: TaskBoardAutomationScope,
}

impl AsyncDaemonDb {
    pub(crate) async fn try_acquire_task_board_automation_run(
        &self,
        request: &TaskBoardRunAcquireRequest,
    ) -> Result<TaskBoardAutomationRunAdmission, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board automation run acquire")
            .await?;
        ensure_control_row(&mut transaction, request.now).await?;
        let expired_events =
            super::recovery::expire_stale_runs(&mut transaction, request.now).await?;
        if let Some(run_id) = active_run_id(&mut transaction).await? {
            return commit_non_acquired_run(
                transaction,
                expired_events,
                TaskBoardAutomationRunAdmission::Busy { run_id },
                "busy",
            )
            .await;
        }
        let control = load_control_in_tx(&mut transaction).await?;
        if !trigger_is_enabled(request.trigger, &control) {
            return commit_non_acquired_run(
                transaction,
                expired_events,
                TaskBoardAutomationRunAdmission::Disabled,
                "disabled",
            )
            .await;
        }
        let lease_epoch = next_lease_epoch(&mut transaction).await?;
        insert_run(&mut transaction, request, &control, lease_epoch).await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        let started_event = insert_automation_audit(
            &mut transaction,
            "task_board.automation.run.started",
            &request.run_id,
            &request.scope,
            &request.now.to_rfc3339(),
            json!({ "trigger": request.trigger, "dry_run": request.dry_run }),
        )
        .await?;
        let mut events = expired_events;
        events.push(started_event);
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board automation run: {error}")))?;
        broadcast_automation_audits(&events);
        Ok(TaskBoardAutomationRunAdmission::Acquired(run_lease(
            request,
            &control,
            lease_epoch,
        )))
    }

    pub(crate) async fn heartbeat_task_board_automation_run(
        &self,
        lease: &TaskBoardAutomationRunLease,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationRunFence, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board automation run heartbeat")
            .await?;
        let row = load_run_fence(&mut transaction, lease).await?;
        if row.lease_expires_at <= now {
            return Err(expired_lease(&lease.run_id));
        }
        let control = load_control_in_tx(&mut transaction).await?;
        let fence = run_fence(lease, &control, &row.state);
        renew_run_lease(&mut transaction, lease, now).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit task board automation heartbeat: {error}"))
        })?;
        Ok(fence)
    }

    pub(crate) async fn finalize_task_board_automation_run(
        &self,
        lease: &TaskBoardAutomationRunLease,
        outcome: TaskBoardAutomationRunOutcome,
        error_kind: Option<&str>,
        error: Option<&str>,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationRunOutcome, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board automation run finalize")
            .await?;
        let row = load_run_fence(&mut transaction, lease).await?;
        if row.lease_expires_at <= now {
            return Err(lost_lease(&lease.run_id));
        }
        let control = load_control_in_tx(&mut transaction).await?;
        let outcome = final_outcome(lease, &control, &row.state, outcome);
        finalize_run_row(&mut transaction, lease, outcome, error_kind, error, now).await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        let event = insert_automation_audit(
            &mut transaction,
            terminal_event_type(outcome),
            &lease.run_id,
            &row.scope,
            &now.to_rfc3339(),
            json!({
                "outcome": outcome,
                "error_kind": error_kind,
                "error": error,
            }),
        )
        .await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit task board automation run finalization: {error}"
            ))
        })?;
        broadcast_automation_audits(std::slice::from_ref(&event));
        Ok(outcome)
    }
}

async fn commit_non_acquired_run(
    mut transaction: Transaction<'_, Sqlite>,
    events: Vec<HarnessMonitorAuditEvent>,
    admission: TaskBoardAutomationRunAdmission,
    context: &str,
) -> Result<TaskBoardAutomationRunAdmission, CliError> {
    if !events.is_empty() {
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    }
    transaction.commit().await.map_err(|error| {
        db_error(format!(
            "commit {context} task board automation run: {error}"
        ))
    })?;
    broadcast_automation_audits(&events);
    Ok(admission)
}

async fn active_run_id(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<Option<String>, CliError> {
    query_as::<_, (String,)>(
        "SELECT run_id FROM task_board_orchestrator_runs
         WHERE state IN ('running', 'cancelling') LIMIT 1",
    )
    .fetch_optional(transaction.as_mut())
    .await
    .map(|row| row.map(|row| row.0))
    .map_err(|error| db_error(format!("load active task board automation run: {error}")))
}

async fn next_lease_epoch(transaction: &mut Transaction<'_, Sqlite>) -> Result<u64, CliError> {
    let value = query_as::<_, (i64,)>(
        "SELECT COALESCE(MAX(lease_epoch), 0) + 1 FROM task_board_orchestrator_runs",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("allocate task board run lease epoch: {error}")))?
    .0;
    u64::try_from(value)
        .map_err(|error| db_error(format!("parse task board run lease epoch: {error}")))
}

async fn insert_run(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &TaskBoardRunAcquireRequest,
    control: &TaskBoardAutomationControlRecord,
    lease_epoch: u64,
) -> Result<(), CliError> {
    let scope_json = serde_json::to_string(&request.scope)
        .map_err(|error| db_error(format!("serialize task board run scope: {error}")))?;
    let lease_expires_at = request.now + Duration::seconds(RUN_LEASE_SECONDS);
    query(
        "INSERT INTO task_board_orchestrator_runs (
            run_id, trigger, actor, dry_run, scope_json, state, lease_owner, lease_epoch,
            lease_expires_at, stop_generation, started_at, heartbeat_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, 'running', ?6, ?7, ?8, ?9, ?10, ?10)",
    )
    .bind(&request.run_id)
    .bind(run_trigger_label(request.trigger))
    .bind(&request.actor)
    .bind(request.dry_run)
    .bind(scope_json)
    .bind(&request.lease_owner)
    .bind(to_db_integer(lease_epoch))
    .bind(lease_expires_at.to_rfc3339())
    .bind(to_db_integer(control.stop_generation))
    .bind(request.now.to_rfc3339())
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("insert task board automation run: {error}")))
}

async fn load_run_fence(
    transaction: &mut Transaction<'_, Sqlite>,
    lease: &TaskBoardAutomationRunLease,
) -> Result<RunFenceRow, CliError> {
    let row = query_as::<_, (String, String, String)>(
        "SELECT state, lease_expires_at, scope_json FROM task_board_orchestrator_runs
         WHERE run_id = ?1 AND lease_owner = ?2 AND lease_epoch = ?3
           AND state IN ('running', 'cancelling')",
    )
    .bind(&lease.run_id)
    .bind(&lease.lease_owner)
    .bind(to_db_integer(lease.lease_epoch))
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load task board run fence: {error}")))?
    .ok_or_else(|| lost_lease(&lease.run_id))?;
    let expires_at = DateTime::parse_from_rfc3339(&row.1)
        .map_err(|error| db_error(format!("parse task board run lease expiry: {error}")))?
        .with_timezone(&Utc);
    Ok(RunFenceRow {
        state: row.0,
        lease_expires_at: expires_at,
        scope: parse_scope(&row.2, &lease.run_id)?,
    })
}

async fn renew_run_lease(
    transaction: &mut Transaction<'_, Sqlite>,
    lease: &TaskBoardAutomationRunLease,
    now: DateTime<Utc>,
) -> Result<(), CliError> {
    let expires_at = now + Duration::seconds(RUN_LEASE_SECONDS);
    let changed = query(
        "UPDATE task_board_orchestrator_runs
         SET heartbeat_at = ?4, lease_expires_at = ?5, revision = revision + 1
         WHERE run_id = ?1 AND lease_owner = ?2 AND lease_epoch = ?3
           AND state IN ('running', 'cancelling')",
    )
    .bind(&lease.run_id)
    .bind(&lease.lease_owner)
    .bind(to_db_integer(lease.lease_epoch))
    .bind(now.to_rfc3339())
    .bind(expires_at.to_rfc3339())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("heartbeat task board automation run: {error}")))?
    .rows_affected();
    ensure_single_run_changed(changed, &lease.run_id)
}

async fn finalize_run_row(
    transaction: &mut Transaction<'_, Sqlite>,
    lease: &TaskBoardAutomationRunLease,
    outcome: TaskBoardAutomationRunOutcome,
    error_kind: Option<&str>,
    error: Option<&str>,
    now: DateTime<Utc>,
) -> Result<(), CliError> {
    let changed = query(
        "UPDATE task_board_orchestrator_runs
         SET state = 'terminal', outcome = ?4, completed_at = ?5,
             heartbeat_at = ?5, error_kind = ?6, error = ?7, revision = revision + 1
         WHERE run_id = ?1 AND lease_owner = ?2 AND lease_epoch = ?3
           AND state IN ('running', 'cancelling')",
    )
    .bind(&lease.run_id)
    .bind(&lease.lease_owner)
    .bind(to_db_integer(lease.lease_epoch))
    .bind(run_outcome_label(outcome))
    .bind(now.to_rfc3339())
    .bind(error_kind)
    .bind(error)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("finalize task board automation run: {error}")))?
    .rows_affected();
    ensure_single_run_changed(changed, &lease.run_id)
}

fn run_lease(
    request: &TaskBoardRunAcquireRequest,
    control: &TaskBoardAutomationControlRecord,
    lease_epoch: u64,
) -> TaskBoardAutomationRunLease {
    TaskBoardAutomationRunLease {
        run_id: request.run_id.clone(),
        trigger: request.trigger,
        lease_owner: request.lease_owner.clone(),
        lease_epoch,
        stop_generation: control.stop_generation,
        started_at: request.now.to_rfc3339(),
    }
}

fn run_fence(
    lease: &TaskBoardAutomationRunLease,
    control: &TaskBoardAutomationControlRecord,
    state: &str,
) -> TaskBoardAutomationRunFence {
    if state == "cancelling"
        || control.stop_generation != lease.stop_generation
        || !admission_is_open(lease.trigger, control)
    {
        TaskBoardAutomationRunFence::Draining
    } else {
        TaskBoardAutomationRunFence::Active
    }
}

fn final_outcome(
    lease: &TaskBoardAutomationRunLease,
    control: &TaskBoardAutomationControlRecord,
    state: &str,
    requested: TaskBoardAutomationRunOutcome,
) -> TaskBoardAutomationRunOutcome {
    if state == "cancelling" || control.stop_generation != lease.stop_generation {
        TaskBoardAutomationRunOutcome::Cancelled
    } else {
        requested
    }
}

fn trigger_is_enabled(
    trigger: TaskBoardAutomationRunTrigger,
    control: &TaskBoardAutomationControlRecord,
) -> bool {
    match trigger {
        TaskBoardAutomationRunTrigger::Manual => {
            control.admission_state != TaskBoardAutomationAdmissionState::Draining
        }
        TaskBoardAutomationRunTrigger::Recovery
        | TaskBoardAutomationRunTrigger::Scheduled
        | TaskBoardAutomationRunTrigger::Event => {
            control.desired_mode == TaskBoardAutomationDesiredMode::Continuous
                && control.admission_state == TaskBoardAutomationAdmissionState::Accepting
        }
    }
}

fn admission_is_open(
    trigger: TaskBoardAutomationRunTrigger,
    control: &TaskBoardAutomationControlRecord,
) -> bool {
    trigger == TaskBoardAutomationRunTrigger::Manual
        || control.admission_state == TaskBoardAutomationAdmissionState::Accepting
}

pub(super) const fn run_trigger_label(trigger: TaskBoardAutomationRunTrigger) -> &'static str {
    match trigger {
        TaskBoardAutomationRunTrigger::Scheduled => "scheduled",
        TaskBoardAutomationRunTrigger::Event => "event",
        TaskBoardAutomationRunTrigger::Manual => "manual",
        TaskBoardAutomationRunTrigger::Recovery => "recovery",
    }
}

pub(super) const fn run_outcome_label(outcome: TaskBoardAutomationRunOutcome) -> &'static str {
    match outcome {
        TaskBoardAutomationRunOutcome::Completed => "completed",
        TaskBoardAutomationRunOutcome::Noop => "noop",
        TaskBoardAutomationRunOutcome::Partial => "partial",
        TaskBoardAutomationRunOutcome::Failed => "failed",
        TaskBoardAutomationRunOutcome::Cancelled => "cancelled",
    }
}

fn ensure_single_run_changed(changed: u64, run_id: &str) -> Result<(), CliError> {
    if changed == 1 {
        Ok(())
    } else {
        Err(lost_lease(run_id))
    }
}

fn to_db_integer(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn expired_lease(run_id: &str) -> CliError {
    db_error(format!(
        "task board automation run '{run_id}' lease expired"
    ))
}

fn lost_lease(run_id: &str) -> CliError {
    db_error(format!(
        "task board automation run '{run_id}' lost its coordinator lease"
    ))
}
