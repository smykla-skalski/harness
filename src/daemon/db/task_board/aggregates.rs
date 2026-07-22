//! Database-backed Task Board singleton aggregates and machine registry.

use std::collections::BTreeSet;

use serde::de::DeserializeOwned;

use sqlx::{Sqlite, Transaction, query, query_as};

use super::mapper::{machine_from_row, parse_json, to_json};
use super::remote_assignment_start_authority::refuse_settings_replacement_during_executor_start_io;
use super::remote_hosts::sync_remote_hosts_in_tx;
use super::rows::MachineRow;
use super::{MACHINES_CHANGE_SCOPE, ORCHESTRATOR_CHANGE_SCOPE, RUNTIME_CONFIG_CHANGE_SCOPE};
use crate::daemon::db::task_board::items::bump_change_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::{
    Machine, TaskBoardGitRuntimeConfig, TaskBoardOrchestratorSettings, TaskBoardOrchestratorState,
    validate_local_execution_host_config, validate_remote_execution_configuration,
};

pub(super) struct TaskBoardOrchestratorSettingsMutation {
    pub(super) row_revision: i64,
    pub(super) change_revision: i64,
}

pub(crate) struct TaskBoardOrchestratorSettingsSnapshot {
    pub(crate) settings: TaskBoardOrchestratorSettings,
    pub(crate) row_revision: i64,
    pub(crate) change_revision: i64,
}

impl AsyncDaemonDb {
    pub(crate) async fn task_board_machines(&self) -> Result<Vec<Machine>, CliError> {
        let rows = query_as::<_, MachineRow>(
            "SELECT machine_id, label, project_types_json,
            agent_modes_json, last_seen FROM task_board_machines ORDER BY machine_id",
        )
        .fetch_all(self.pool())
        .await
        .map_err(|error| db_error(format!("list task board machines: {error}")))?;
        rows.into_iter().map(machine_from_row).collect()
    }

    pub(crate) async fn upsert_task_board_machine(
        &self,
        machine: &Machine,
    ) -> Result<(Machine, i64), CliError> {
        let mut stored = machine.clone();
        stored.project_types = normalize_strings(&stored.project_types);
        stored.last_seen = utc_now();
        let mut transaction = self
            .begin_immediate_transaction("task board machine upsert")
            .await?;
        upsert_machine_in_tx(&mut transaction, &stored).await?;
        let change_revision = bump_change_in_tx(&mut transaction, MACHINES_CHANGE_SCOPE).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board machine: {error}")))?;
        Ok((stored, change_revision))
    }

    pub(crate) async fn task_board_local_machine_id(&self) -> Result<Option<String>, CliError> {
        query_as::<_, (String,)>(
            "SELECT machine_id FROM task_board_local_machine WHERE singleton = 1",
        )
        .fetch_optional(self.pool())
        .await
        .map(|row| row.map(|row| row.0))
        .map_err(|error| db_error(format!("load local task board machine: {error}")))
    }

    pub(crate) async fn set_task_board_local_machine(
        &self,
        machine: &Machine,
    ) -> Result<(Machine, i64), CliError> {
        let mut stored = machine.clone();
        stored.project_types = normalize_strings(&stored.project_types);
        stored.last_seen = utc_now();
        let mut transaction = self
            .begin_immediate_transaction("task board local machine set")
            .await?;
        upsert_machine_in_tx(&mut transaction, &stored).await?;
        query(
            "INSERT INTO task_board_local_machine (singleton, machine_id) VALUES (1, ?1)
            ON CONFLICT(singleton) DO UPDATE SET machine_id = excluded.machine_id",
        )
        .bind(&stored.id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("set local task board machine: {error}")))?;
        let change_revision = bump_change_in_tx(&mut transaction, MACHINES_CHANGE_SCOPE).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit local task board machine: {error}")))?;
        Ok((stored, change_revision))
    }

    pub(crate) async fn touch_task_board_local_machine(
        &self,
    ) -> Result<Option<(Machine, i64)>, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board local machine heartbeat")
            .await?;
        let row = query_as::<_, MachineRow>(
            "SELECT machines.machine_id, machines.label, machines.project_types_json,
                machines.agent_modes_json, machines.last_seen
             FROM task_board_local_machine AS pointer
             JOIN task_board_machines AS machines ON machines.machine_id = pointer.machine_id
             WHERE pointer.singleton = 1",
        )
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load local task board machine: {error}")))?;
        let Some(row) = row else {
            transaction
                .rollback()
                .await
                .map_err(|error| db_error(format!("rollback missing local machine: {error}")))?;
            return Ok(None);
        };
        let mut machine = machine_from_row(row)?;
        machine.last_seen = utc_now();
        query(
            "UPDATE task_board_machines SET last_seen = ?2, revision = revision + 1
             WHERE machine_id = ?1",
        )
        .bind(&machine.id)
        .bind(&machine.last_seen)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("touch local task board machine: {error}")))?;
        let change_revision = bump_change_in_tx(&mut transaction, MACHINES_CHANGE_SCOPE).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit local machine heartbeat: {error}")))?;
        Ok(Some((machine, change_revision)))
    }

    pub(crate) async fn task_board_orchestrator_settings(
        &self,
    ) -> Result<TaskBoardOrchestratorSettings, CliError> {
        self.task_board_orchestrator_settings_snapshot()
            .await
            .map(|snapshot| snapshot.settings)
    }

    pub(crate) async fn task_board_orchestrator_settings_snapshot(
        &self,
    ) -> Result<TaskBoardOrchestratorSettingsSnapshot, CliError> {
        let (settings_json, row_revision, change_revision) = query_as::<_, (String, i64, i64)>(
            "SELECT settings.settings_json, settings.revision,
                        COALESCE(changes.change_seq, 0)
                 FROM task_board_orchestrator_settings AS settings
                 LEFT JOIN change_tracking AS changes ON changes.scope = ?1
                 WHERE settings.singleton = 1",
        )
        .bind(ORCHESTRATOR_CHANGE_SCOPE)
        .fetch_one(self.pool())
        .await
        .map_err(|error| db_error(format!("load orchestrator settings: {error}")))?;
        Ok(TaskBoardOrchestratorSettingsSnapshot {
            settings: parse_json(&settings_json, "task board orchestrator settings")?,
            row_revision,
            change_revision,
        })
    }

    pub(crate) async fn replace_task_board_orchestrator_settings(
        &self,
        settings: &TaskBoardOrchestratorSettings,
    ) -> Result<i64, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board orchestrator settings")
            .await?;
        let revision = replace_orchestrator_settings_in_tx(&mut transaction, settings).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit orchestrator settings: {error}")))?;
        Ok(revision.change_revision)
    }

    pub(crate) async fn task_board_orchestrator_state(
        &self,
    ) -> Result<TaskBoardOrchestratorState, CliError> {
        load_singleton_json(
            self,
            "SELECT state_json FROM task_board_orchestrator_state WHERE singleton = 1",
            "task board orchestrator state",
        )
        .await
        .map(Option::unwrap_or_default)
    }

    pub(crate) async fn replace_task_board_orchestrator_state(
        &self,
        state: &TaskBoardOrchestratorState,
    ) -> Result<i64, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board orchestrator state")
            .await?;
        query(
            "INSERT INTO task_board_orchestrator_state (
            singleton, state_json, enabled, running, revision, updated_at
        ) VALUES (1, ?1, ?2, ?3, 1, ?4)
        ON CONFLICT(singleton) DO UPDATE SET state_json = excluded.state_json,
            enabled = excluded.enabled, running = excluded.running,
            revision = task_board_orchestrator_state.revision + 1,
            updated_at = excluded.updated_at",
        )
        .bind(to_json(state, "task board orchestrator state")?)
        .bind(state.enabled)
        .bind(state.running)
        .bind(utc_now())
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("save orchestrator state: {error}")))?;
        let revision = bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit orchestrator state: {error}")))?;
        Ok(revision)
    }

    pub(crate) async fn task_board_runtime_config(
        &self,
    ) -> Result<TaskBoardGitRuntimeConfig, CliError> {
        load_singleton_json(
            self,
            "SELECT config_json FROM task_board_runtime_config WHERE singleton = 1",
            "task board runtime config",
        )
        .await
        .map(Option::unwrap_or_default)
    }

    pub(crate) async fn replace_task_board_runtime_config(
        &self,
        config: &TaskBoardGitRuntimeConfig,
    ) -> Result<i64, CliError> {
        let config = config.without_secret_metadata();
        let mut transaction = self
            .begin_immediate_transaction("task board runtime config")
            .await?;
        query(
            "INSERT INTO task_board_runtime_config (
            singleton, config_json, revision, updated_at
        ) VALUES (1, ?1, 1, ?2)
        ON CONFLICT(singleton) DO UPDATE SET config_json = excluded.config_json,
            revision = task_board_runtime_config.revision + 1,
            updated_at = excluded.updated_at",
        )
        .bind(to_json(&config, "task board runtime config")?)
        .bind(utc_now())
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("save task board runtime config: {error}")))?;
        let revision = bump_change_in_tx(&mut transaction, RUNTIME_CONFIG_CHANGE_SCOPE).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board runtime config: {error}")))?;
        Ok(revision)
    }
}

pub(super) async fn replace_orchestrator_settings_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    settings: &TaskBoardOrchestratorSettings,
) -> Result<TaskBoardOrchestratorSettingsMutation, CliError> {
    validate_remote_execution_configuration(&settings.execution_hosts, &settings.repositories)?;
    validate_local_execution_host_config(&settings.local_execution_host)?;
    refuse_settings_replacement_during_executor_start_io(transaction).await?;
    query(
        "INSERT INTO task_board_orchestrator_settings (
            singleton, settings_json, revision, updated_at
         ) VALUES (1, ?1, 1, ?2)
         ON CONFLICT(singleton) DO UPDATE SET settings_json = excluded.settings_json,
             revision = task_board_orchestrator_settings.revision + 1,
             updated_at = excluded.updated_at",
    )
    .bind(to_json(settings, "task board orchestrator settings")?)
    .bind(utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("save orchestrator settings: {error}")))?;
    let row_revision = query_as::<_, (i64,)>(
        "SELECT revision FROM task_board_orchestrator_settings WHERE singleton = 1",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map(|row| row.0)
    .map_err(|error| db_error(format!("read orchestrator settings revision: {error}")))?;
    sync_remote_hosts_in_tx(transaction, settings, row_revision).await?;
    let change_revision = bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    Ok(TaskBoardOrchestratorSettingsMutation {
        row_revision,
        change_revision,
    })
}

pub(super) async fn upsert_machine_in_tx(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    machine: &Machine,
) -> Result<(), CliError> {
    query(
        "INSERT INTO task_board_machines (
        machine_id, label, project_types_json, agent_modes_json, last_seen, revision
    ) VALUES (?1, ?2, ?3, ?4, ?5, 1)
    ON CONFLICT(machine_id) DO UPDATE SET
        label = excluded.label,
        project_types_json = excluded.project_types_json,
        agent_modes_json = excluded.agent_modes_json,
        last_seen = excluded.last_seen,
        revision = task_board_machines.revision + 1",
    )
    .bind(&machine.id)
    .bind(&machine.label)
    .bind(to_json(&machine.project_types, "machine project types")?)
    .bind(to_json(&machine.agent_modes, "machine agent modes")?)
    .bind(&machine.last_seen)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("upsert task board machine: {error}")))?;
    Ok(())
}

async fn load_singleton_json<T: DeserializeOwned>(
    db: &AsyncDaemonDb,
    sql: &'static str,
    context: &str,
) -> Result<Option<T>, CliError> {
    query_as::<_, (String,)>(sql)
        .fetch_optional(db.pool())
        .await
        .map_err(|error| db_error(format!("load {context}: {error}")))?
        .map(|row| parse_json(&row.0, context))
        .transpose()
}

fn normalize_strings(values: &[String]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut normalized = Vec::new();
    for value in values {
        let value = value.trim();
        if !value.is_empty() && seen.insert(value.to_lowercase()) {
            normalized.push(value.to_owned());
        }
    }
    normalized
}
