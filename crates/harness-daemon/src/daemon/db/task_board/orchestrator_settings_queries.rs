//! Orchestrator-settings' own interface onto [`AsyncDaemonDb`], scoped to the
//! machine registry and the singleton orchestrator settings, orchestrator
//! state, and runtime-config records every other task-board area and most of
//! the daemon's service layer read to know how execution is configured.
//!
//! `task_board` doesn't own `AsyncDaemonDb` -- it's a sibling module's type --
//! so an inherent `impl AsyncDaemonDb` block for orchestrator-settings queries
//! can never move into a crate `task_board` doesn't share with `db`. A trait
//! `task_board` itself declares has no such problem: Rust's orphan rule only
//! requires one of the trait or the implementing type to be local, and the
//! trait is. That is what lets this one area's queries move into their own
//! crate later without dragging every other area's inherent impls along for
//! the ride.
//!
//! `AsyncDaemonDb` keeps its original inherent methods too, each now a thin
//! forward into the matching trait method, so nothing outside `db/task_board`
//! has to change to keep calling them by the same name.

use super::aggregates::TaskBoardOrchestratorSettingsSnapshot;
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::{
    Machine, TaskBoardGitRuntimeConfig, TaskBoardOrchestratorSettings, TaskBoardOrchestratorState,
};

pub(crate) trait OrchestratorSettingsQueries: Send + Sync {
    /// Every registered machine.
    ///
    /// # Errors
    /// Returns [`CliError`] when the registry cannot be read.
    async fn task_board_machines(&self) -> Result<Vec<Machine>, CliError>;

    /// Register or update a machine's advertised capabilities.
    ///
    /// # Errors
    /// Returns [`CliError`] when the registry cannot be written.
    async fn upsert_task_board_machine(
        &self,
        machine: &Machine,
    ) -> Result<(Machine, i64), CliError>;

    /// The identifier of the machine this daemon instance runs as, if one has
    /// been claimed yet.
    ///
    /// # Errors
    /// Returns [`CliError`] when the pointer cannot be read.
    async fn task_board_local_machine_id(&self) -> Result<Option<String>, CliError>;

    /// Register `machine` and point this daemon instance at it.
    ///
    /// # Errors
    /// Returns [`CliError`] when the registry or pointer cannot be written.
    async fn set_task_board_local_machine(
        &self,
        machine: &Machine,
    ) -> Result<(Machine, i64), CliError>;

    /// Refresh the local machine's `last_seen` heartbeat. `None` when no
    /// local machine has been claimed yet.
    ///
    /// # Errors
    /// Returns [`CliError`] when the registry cannot be read or written.
    async fn touch_task_board_local_machine(&self) -> Result<Option<(Machine, i64)>, CliError>;

    /// The current orchestrator settings singleton.
    ///
    /// # Errors
    /// Returns [`CliError`] when the singleton cannot be read.
    async fn task_board_orchestrator_settings(
        &self,
    ) -> Result<TaskBoardOrchestratorSettings, CliError>;

    /// The current orchestrator settings singleton, plus the row and
    /// change-tracking revisions callers CAS against.
    ///
    /// # Errors
    /// Returns [`CliError`] when the singleton cannot be read.
    async fn task_board_orchestrator_settings_snapshot(
        &self,
    ) -> Result<TaskBoardOrchestratorSettingsSnapshot, CliError>;

    /// Replace the orchestrator settings singleton, registering every
    /// configured repository as a project and syncing configured remote hosts
    /// in the same transaction.
    ///
    /// # Errors
    /// Returns [`CliError`] when the settings are invalid or cannot be
    /// written.
    async fn replace_task_board_orchestrator_settings(
        &self,
        settings: &TaskBoardOrchestratorSettings,
    ) -> Result<i64, CliError>;

    /// The current orchestrator state singleton, defaulted when absent.
    ///
    /// # Errors
    /// Returns [`CliError`] when the singleton cannot be read.
    async fn task_board_orchestrator_state(&self) -> Result<TaskBoardOrchestratorState, CliError>;

    /// Replace the orchestrator state singleton.
    ///
    /// # Errors
    /// Returns [`CliError`] when the singleton cannot be written.
    async fn replace_task_board_orchestrator_state(
        &self,
        state: &TaskBoardOrchestratorState,
    ) -> Result<i64, CliError>;

    /// The current git runtime config singleton, defaulted when absent.
    ///
    /// # Errors
    /// Returns [`CliError`] when the singleton cannot be read.
    async fn task_board_runtime_config(&self) -> Result<TaskBoardGitRuntimeConfig, CliError>;

    /// Replace the git runtime config singleton. Secret metadata is stripped
    /// before the value is stored.
    ///
    /// # Errors
    /// Returns [`CliError`] when the singleton cannot be written.
    async fn replace_task_board_runtime_config(
        &self,
        config: &TaskBoardGitRuntimeConfig,
    ) -> Result<i64, CliError>;
}

/// The trait's one and only impl for [`AsyncDaemonDb`]. Every method is a
/// thin, single-line forward into the free function that actually owns the
/// area's query logic, kept in `aggregates.rs` so this file stays a pure
/// interface plus wiring, not a dumping ground.
impl OrchestratorSettingsQueries for AsyncDaemonDb {
    async fn task_board_machines(&self) -> Result<Vec<Machine>, CliError> {
        super::aggregates::task_board_machines(self).await
    }

    async fn upsert_task_board_machine(
        &self,
        machine: &Machine,
    ) -> Result<(Machine, i64), CliError> {
        super::aggregates::upsert_task_board_machine(self, machine).await
    }

    async fn task_board_local_machine_id(&self) -> Result<Option<String>, CliError> {
        super::aggregates::task_board_local_machine_id(self).await
    }

    async fn set_task_board_local_machine(
        &self,
        machine: &Machine,
    ) -> Result<(Machine, i64), CliError> {
        super::aggregates::set_task_board_local_machine(self, machine).await
    }

    async fn touch_task_board_local_machine(&self) -> Result<Option<(Machine, i64)>, CliError> {
        super::aggregates::touch_task_board_local_machine(self).await
    }

    async fn task_board_orchestrator_settings(
        &self,
    ) -> Result<TaskBoardOrchestratorSettings, CliError> {
        super::aggregates::task_board_orchestrator_settings(self).await
    }

    async fn task_board_orchestrator_settings_snapshot(
        &self,
    ) -> Result<TaskBoardOrchestratorSettingsSnapshot, CliError> {
        super::aggregates::task_board_orchestrator_settings_snapshot(self).await
    }

    async fn replace_task_board_orchestrator_settings(
        &self,
        settings: &TaskBoardOrchestratorSettings,
    ) -> Result<i64, CliError> {
        super::aggregates::replace_task_board_orchestrator_settings(self, settings).await
    }

    async fn task_board_orchestrator_state(&self) -> Result<TaskBoardOrchestratorState, CliError> {
        super::aggregates::task_board_orchestrator_state(self).await
    }

    async fn replace_task_board_orchestrator_state(
        &self,
        state: &TaskBoardOrchestratorState,
    ) -> Result<i64, CliError> {
        super::aggregates::replace_task_board_orchestrator_state(self, state).await
    }

    async fn task_board_runtime_config(&self) -> Result<TaskBoardGitRuntimeConfig, CliError> {
        super::aggregates::task_board_runtime_config(self).await
    }

    async fn replace_task_board_runtime_config(
        &self,
        config: &TaskBoardGitRuntimeConfig,
    ) -> Result<i64, CliError> {
        super::aggregates::replace_task_board_runtime_config(self, config).await
    }
}
