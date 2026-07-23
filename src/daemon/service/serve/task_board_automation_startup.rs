use std::sync::{Arc, OnceLock};

use chrono::{DateTime, Utc};

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::{CliError, CliErrorKind};
use crate::feature_flags::task_board_automation_v2_enabled_from_env;
use crate::task_board::{
    TaskBoardAutomationDesiredMode, TaskBoardOrchestratorSettings, TaskBoardOrchestratorState,
};

pub(super) async fn initialize_control_before_serving(
    async_db_slot: &Arc<OnceLock<Arc<AsyncDaemonDb>>>,
) -> Result<(), CliError> {
    if !task_board_automation_v2_enabled_from_env() {
        return Ok(());
    }
    let db = async_db_slot.get().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "task-board automation startup requires the async daemon database",
        ))
    })?;
    initialize_control_from_legacy_intent(db, Utc::now()).await?;
    Ok(())
}

pub(super) async fn initialize_control_from_legacy_intent(
    db: &AsyncDaemonDb,
    now: DateTime<Utc>,
) -> Result<(), CliError> {
    let state = db.task_board_orchestrator_state().await?;
    let settings = db.task_board_orchestrator_settings().await?;
    db.initialize_task_board_automation_control_from_legacy_intent(
        desired_mode_for_legacy_intent(&state, &settings),
        now,
    )
    .await?;
    Ok(())
}

const fn desired_mode_for_legacy_intent(
    state: &TaskBoardOrchestratorState,
    settings: &TaskBoardOrchestratorSettings,
) -> TaskBoardAutomationDesiredMode {
    if !state.enabled || !state.running {
        return TaskBoardAutomationDesiredMode::Off;
    }
    if settings.step_mode {
        TaskBoardAutomationDesiredMode::Step
    } else {
        TaskBoardAutomationDesiredMode::Continuous
    }
}

#[cfg(test)]
#[path = "task_board_automation_startup_tests.rs"]
mod tests;
