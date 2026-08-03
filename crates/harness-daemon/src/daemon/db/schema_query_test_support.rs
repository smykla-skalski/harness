//! Narrow task-board query facade for `harness-db-schema` migration tests.

use super::task_board::prelude::{
    ItemCoreQueries, OrchestratorSettingsQueries, RemoteExecutionQueries,
};
use super::{AsyncDaemonDb, CliError};
use crate::task_board::{TaskBoardItem, TaskBoardOrchestratorSettings};

/// Insert one task-board item needed by a migration fixture.
///
/// # Errors
/// Returns [`CliError`] when the fixture item cannot be inserted.
pub async fn create_task_board_item(
    db: &AsyncDaemonDb,
    item: TaskBoardItem,
) -> Result<(), CliError> {
    Box::pin(ItemCoreQueries::create_task_board_item(db, item))
        .await
        .map(|_| ())
}

/// Load the orchestrator settings used by a migration fixture.
///
/// # Errors
/// Returns [`CliError`] when the settings cannot be loaded.
pub async fn task_board_orchestrator_settings(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardOrchestratorSettings, CliError> {
    OrchestratorSettingsQueries::task_board_orchestrator_settings(db).await
}

/// Replace the orchestrator settings used by a migration fixture.
///
/// # Errors
/// Returns [`CliError`] when the settings cannot be replaced.
pub async fn replace_task_board_orchestrator_settings(
    db: &AsyncDaemonDb,
    settings: &TaskBoardOrchestratorSettings,
) -> Result<(), CliError> {
    OrchestratorSettingsQueries::replace_task_board_orchestrator_settings(db, settings)
        .await
        .map(|_| ())
}

/// Report whether a typed remote-assignment row can be loaded.
///
/// # Errors
/// Returns [`CliError`] when the stored assignment cannot be decoded.
pub async fn task_board_remote_assignment_exists(
    db: &AsyncDaemonDb,
    assignment_id: &str,
) -> Result<bool, CliError> {
    RemoteExecutionQueries::task_board_remote_assignment(db, assignment_id)
        .await
        .map(|assignment| assignment.is_some())
}
