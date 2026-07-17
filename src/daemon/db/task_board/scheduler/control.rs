use chrono::{DateTime, Utc};
use sqlx::{Sqlite, Transaction, query, query_as};

use super::super::ORCHESTRATOR_CHANGE_SCOPE;
use super::super::items::bump_change_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::{
    TaskBoardAutomationAdmissionState, TaskBoardAutomationDesiredMode,
    TaskBoardAutomationWakeEntityKind, TaskBoardAutomationWakePayload,
    TaskBoardAutomationWakeRequest, TaskBoardOrchestratorSettings,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardAutomationControlRecord {
    pub(crate) desired_mode: TaskBoardAutomationDesiredMode,
    pub(crate) admission_state: TaskBoardAutomationAdmissionState,
    pub(crate) stop_generation: u64,
    pub(crate) updated_at: String,
}

impl Default for TaskBoardAutomationControlRecord {
    fn default() -> Self {
        Self {
            desired_mode: TaskBoardAutomationDesiredMode::Off,
            admission_state: TaskBoardAutomationAdmissionState::Stopped,
            stop_generation: 0,
            updated_at: String::new(),
        }
    }
}

impl AsyncDaemonDb {
    pub(crate) async fn initialize_task_board_automation_control_from_legacy_intent(
        &self,
        desired_mode: TaskBoardAutomationDesiredMode,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationControlRecord, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board automation control initialization")
            .await?;
        let admission_state = admission_state_for_mode(desired_mode);
        query(
            "INSERT INTO task_board_orchestrator_control (
                singleton, desired_mode, admission_state, stop_generation, updated_at
             ) VALUES (1, ?1, ?2, 0, ?3)
             ON CONFLICT(singleton) DO UPDATE SET
                 desired_mode = excluded.desired_mode,
                 admission_state = excluded.admission_state,
                 updated_at = excluded.updated_at
             WHERE task_board_orchestrator_control.desired_mode = 'off'
               AND task_board_orchestrator_control.admission_state = 'stopped'
               AND task_board_orchestrator_control.stop_generation = 0
               AND excluded.desired_mode != 'off'",
        )
        .bind(desired_mode_label(desired_mode))
        .bind(admission_state)
        .bind(now.to_rfc3339())
        .execute(transaction.as_mut())
        .await
        .map_err(|error| {
            db_error(format!(
                "initialize task board automation control from legacy intent: {error}"
            ))
        })?;
        let control = load_control_in_tx(&mut transaction).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit task board automation control initialization: {error}"
            ))
        })?;
        Ok(control)
    }

    pub(crate) async fn task_board_automation_control(
        &self,
    ) -> Result<TaskBoardAutomationControlRecord, CliError> {
        let row = query_as::<_, (String, String, i64, String)>(
            "SELECT desired_mode, admission_state, stop_generation, updated_at
             FROM task_board_orchestrator_control WHERE singleton = 1",
        )
        .fetch_optional(self.pool())
        .await
        .map_err(|error| db_error(format!("load task board automation control: {error}")))?;
        row.map(control_from_row)
            .transpose()
            .map(Option::unwrap_or_default)
    }

    pub(crate) async fn start_task_board_automation(
        &self,
        desired_mode: TaskBoardAutomationDesiredMode,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationControlRecord, CliError> {
        self.start_task_board_automation_inner(desired_mode, None, now)
            .await
    }

    pub(crate) async fn start_task_board_automation_with_wake(
        &self,
        desired_mode: TaskBoardAutomationDesiredMode,
        wake: &TaskBoardAutomationWakeRequest,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationControlRecord, CliError> {
        self.start_task_board_automation_inner(desired_mode, Some(wake), now)
            .await
    }

    async fn start_task_board_automation_inner(
        &self,
        desired_mode: TaskBoardAutomationDesiredMode,
        wake: Option<&TaskBoardAutomationWakeRequest>,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationControlRecord, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board automation start")
            .await?;
        ensure_control_row(&mut transaction, now).await?;
        query(
            "UPDATE task_board_orchestrator_control
             SET desired_mode = ?1, admission_state = 'accepting', updated_at = ?2
             WHERE singleton = 1",
        )
        .bind(desired_mode_label(desired_mode))
        .bind(now.to_rfc3339())
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("start task board automation: {error}")))?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        if let Some(wake) = wake {
            super::wake::enqueue_in_tx(&mut transaction, wake, now).await?;
        }
        let control = load_control_in_tx(&mut transaction).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board automation start: {error}")))?;
        Ok(control)
    }

    pub(crate) async fn replace_task_board_orchestrator_settings_for_automation(
        &self,
        settings: &TaskBoardOrchestratorSettings,
        desired_mode: TaskBoardAutomationDesiredMode,
        now: DateTime<Utc>,
    ) -> Result<i64, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board automation settings update")
            .await?;
        let revision = super::super::aggregates::replace_orchestrator_settings_in_tx(
            &mut transaction,
            settings,
        )
        .await?;
        let changed = query(
            "UPDATE task_board_orchestrator_control
             SET desired_mode = ?1, admission_state = 'accepting', updated_at = ?2
             WHERE singleton = 1 AND desired_mode != 'off'
               AND admission_state = 'accepting'",
        )
        .bind(desired_mode_label(desired_mode))
        .bind(now.to_rfc3339())
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("update task board automation settings: {error}")))?
        .rows_affected();
        if changed > 1 {
            return Err(db_error(
                "task board automation settings updated multiple control rows",
            ));
        }
        if changed == 1 {
            bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
            if desired_mode == TaskBoardAutomationDesiredMode::Continuous {
                let revision = u64::try_from(revision.row_revision).map_err(|error| {
                    db_error(format!("convert task board settings row revision: {error}"))
                })?;
                super::wake::enqueue_in_tx(
                    &mut transaction,
                    &TaskBoardAutomationWakeRequest {
                        entity_id: Some("automation-settings".into()),
                        entity_revision: Some(revision),
                        payload: TaskBoardAutomationWakePayload::ledger_changed(
                            TaskBoardAutomationWakeEntityKind::Settings,
                        ),
                    },
                    now,
                )
                .await?;
            }
        }
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit task board automation settings update: {error}"
            ))
        })?;
        Ok(revision.row_revision)
    }

    pub(crate) async fn stop_task_board_automation(
        &self,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationControlRecord, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board automation stop")
            .await?;
        ensure_control_row(&mut transaction, now).await?;
        query(
            "UPDATE task_board_orchestrator_control
             SET desired_mode = 'off', admission_state = 'draining',
                 stop_generation = stop_generation + 1, updated_at = ?1
             WHERE singleton = 1",
        )
        .bind(now.to_rfc3339())
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("stop task board automation: {error}")))?;
        query(
            "UPDATE task_board_orchestrator_runs
             SET state = 'cancelling', revision = revision + 1
             WHERE state = 'running'",
        )
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("cancel active task board automation run: {error}")))?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        let control = load_control_in_tx(&mut transaction).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board automation stop: {error}")))?;
        Ok(control)
    }

    pub(crate) async fn finish_task_board_automation_drain_if_idle(
        &self,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationControlRecord, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board automation drain completion")
            .await?;
        ensure_control_row(&mut transaction, now).await?;
        let active = active_automation_count(&mut transaction).await?;
        let changed = finish_drain_if_idle(&mut transaction, active, now).await?;
        if changed > 0 {
            bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        }
        let control = load_control_in_tx(&mut transaction).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit task board automation drain completion: {error}"
            ))
        })?;
        Ok(control)
    }
}

pub(super) async fn ensure_control_row(
    transaction: &mut Transaction<'_, Sqlite>,
    now: DateTime<Utc>,
) -> Result<(), CliError> {
    query(
        "INSERT INTO task_board_orchestrator_control (
            singleton, desired_mode, admission_state, stop_generation, updated_at
         ) VALUES (1, 'off', 'stopped', 0, ?1)
         ON CONFLICT(singleton) DO NOTHING",
    )
    .bind(now.to_rfc3339())
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("initialize task board automation control: {error}")))
}

pub(super) async fn load_control_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<TaskBoardAutomationControlRecord, CliError> {
    let row = query_as::<_, (String, String, i64, String)>(
        "SELECT desired_mode, admission_state, stop_generation, updated_at
         FROM task_board_orchestrator_control WHERE singleton = 1",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load task board automation control: {error}")))?;
    control_from_row(row)
}

async fn active_automation_count(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<i64, CliError> {
    query_as::<_, (i64,)>(
        "SELECT COUNT(*) FROM task_board_orchestrator_runs
         WHERE state IN ('running', 'cancelling')",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map(|row| row.0)
    .map_err(|error| db_error(format!("count active task board automation: {error}")))
}

async fn finish_drain_if_idle(
    transaction: &mut Transaction<'_, Sqlite>,
    active: i64,
    now: DateTime<Utc>,
) -> Result<u64, CliError> {
    if active != 0 {
        return Ok(0);
    }
    query(
        "UPDATE task_board_orchestrator_control
         SET admission_state = 'stopped', updated_at = ?1
         WHERE singleton = 1 AND desired_mode = 'off' AND admission_state = 'draining'",
    )
    .bind(now.to_rfc3339())
    .execute(transaction.as_mut())
    .await
    .map(|result| result.rows_affected())
    .map_err(|error| db_error(format!("finish task board automation drain: {error}")))
}

fn control_from_row(
    (desired_mode, admission_state, stop_generation, updated_at): (String, String, i64, String),
) -> Result<TaskBoardAutomationControlRecord, CliError> {
    Ok(TaskBoardAutomationControlRecord {
        desired_mode: parse_desired_mode(&desired_mode)?,
        admission_state: parse_admission_state(&admission_state)?,
        stop_generation: u64::try_from(stop_generation)
            .map_err(|error| db_error(format!("parse task board stop generation: {error}")))?,
        updated_at,
    })
}

pub(super) const fn desired_mode_label(mode: TaskBoardAutomationDesiredMode) -> &'static str {
    match mode {
        TaskBoardAutomationDesiredMode::Off => "off",
        TaskBoardAutomationDesiredMode::Continuous => "continuous",
        TaskBoardAutomationDesiredMode::Step => "step",
    }
}

const fn admission_state_for_mode(mode: TaskBoardAutomationDesiredMode) -> &'static str {
    match mode {
        TaskBoardAutomationDesiredMode::Off => "stopped",
        TaskBoardAutomationDesiredMode::Continuous | TaskBoardAutomationDesiredMode::Step => {
            "accepting"
        }
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
