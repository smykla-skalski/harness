use chrono::Utc;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    TaskBoardOrchestratorSettingsResponse, TaskBoardOrchestratorSettingsUpdateRequest,
    TaskBoardOrchestratorStatusResponse,
};
use crate::errors::CliError;
use crate::feature_flags::task_board_automation_v2_enabled_from_env;
use crate::task_board::{
    TaskBoardAutomationAdmissionState, TaskBoardAutomationDesiredMode,
    TaskBoardOrchestratorSettings, TaskBoardOrchestratorState, TaskBoardWorkflowExecutionCount,
    TaskBoardWorkflowStatus,
};

use super::task_board_db::task_board_host_local_db;
use super::task_board_orchestrator_settings::{
    apply_settings_update, normalize_github_inbox, normalize_todoist_inbox,
};

pub(crate) async fn task_board_orchestrator_status_db(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    let state = db.task_board_orchestrator_state().await?;
    status_from_state(db, state, task_board_automation_v2_enabled_from_env()).await
}

pub(crate) async fn start_task_board_orchestrator_db(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    start_task_board_orchestrator_with_durable(db, task_board_automation_v2_enabled_from_env())
        .await
}

async fn start_task_board_orchestrator_with_durable(
    db: &AsyncDaemonDb,
    durable_enabled: bool,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    if durable_enabled {
        let settings = db.task_board_orchestrator_settings().await?;
        db.start_task_board_automation(desired_mode_for_settings(&settings), Utc::now())
            .await?;
    }
    set_running_intent(db, true, true, durable_enabled).await
}

pub(crate) async fn stop_task_board_orchestrator_db(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    stop_task_board_orchestrator_with_durable(db, task_board_automation_v2_enabled_from_env()).await
}

async fn stop_task_board_orchestrator_with_durable(
    db: &AsyncDaemonDb,
    durable_enabled: bool,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    if durable_enabled {
        let now = Utc::now();
        db.stop_task_board_automation(now).await?;
        db.finish_task_board_automation_drain_if_idle(now).await?;
    }
    set_running_intent(db, false, false, durable_enabled).await
}

pub(crate) async fn task_board_orchestrator_settings_db(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardOrchestratorSettingsResponse, CliError> {
    db.task_board_orchestrator_settings().await
}

pub(crate) async fn update_task_board_orchestrator_settings_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardOrchestratorSettingsUpdateRequest,
) -> Result<TaskBoardOrchestratorSettingsResponse, CliError> {
    let mut settings = db.task_board_orchestrator_settings().await?;
    apply_settings_update(&mut settings, request);
    settings.github_inbox = normalize_github_inbox(&settings.github_inbox)?;
    settings.todoist_inbox = normalize_todoist_inbox(&settings.todoist_inbox);
    db.replace_task_board_orchestrator_settings(&settings)
        .await?;
    update_running_automation_mode(db, &settings, task_board_automation_v2_enabled_from_env())
        .await?;
    Ok(settings)
}

async fn update_running_automation_mode(
    db: &AsyncDaemonDb,
    settings: &TaskBoardOrchestratorSettings,
    durable_enabled: bool,
) -> Result<(), CliError> {
    if !durable_enabled {
        return Ok(());
    }
    let control = db.task_board_automation_control().await?;
    if control.desired_mode != TaskBoardAutomationDesiredMode::Off
        && control.admission_state == TaskBoardAutomationAdmissionState::Accepting
    {
        db.start_task_board_automation(desired_mode_for_settings(settings), Utc::now())
            .await?;
    }
    Ok(())
}

const fn desired_mode_for_settings(
    settings: &TaskBoardOrchestratorSettings,
) -> TaskBoardAutomationDesiredMode {
    if settings.step_mode {
        TaskBoardAutomationDesiredMode::Step
    } else {
        TaskBoardAutomationDesiredMode::Continuous
    }
}

async fn set_running_intent(
    db: &AsyncDaemonDb,
    enabled: bool,
    running: bool,
    durable_enabled: bool,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    let mut state = db.task_board_orchestrator_state().await?;
    state.enabled = enabled;
    state.running = running;
    db.replace_task_board_orchestrator_state(&state).await?;
    status_from_state(db, state, durable_enabled).await
}

async fn status_from_state(
    db: &AsyncDaemonDb,
    state: TaskBoardOrchestratorState,
    durable_enabled: bool,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    let settings = db.task_board_orchestrator_settings().await?;
    let held_dispatches = db.held_task_board_dispatch_summary().await?;
    let machine = task_board_host_local_db(db).await.ok();
    let items = db.list_task_board_items(None).await?;
    let items = items.iter().filter(|item| {
        machine
            .as_ref()
            .is_none_or(|machine| machine.accepts_any(&item.target_project_types))
    });
    let workflow_execution_counts = workflow_statuses()
        .into_iter()
        .filter_map(|status| {
            let count = items
                .clone()
                .filter(|item| item.workflow.status == status)
                .count();
            (count > 0).then_some(TaskBoardWorkflowExecutionCount { status, count })
        })
        .collect();
    let (enabled, running) = if durable_enabled {
        let control = db.task_board_automation_control().await?;
        (
            control.desired_mode != TaskBoardAutomationDesiredMode::Off,
            control.admission_state != TaskBoardAutomationAdmissionState::Stopped,
        )
    } else {
        (state.enabled, state.running)
    };
    Ok(TaskBoardOrchestratorStatusResponse {
        enabled,
        running,
        step_mode: settings.step_mode,
        held_dispatches,
        current_tick: state.current_tick,
        last_run: state.last_run,
        workflow_execution_counts,
        settings,
    })
}

const fn workflow_statuses() -> [TaskBoardWorkflowStatus; 6] {
    [
        TaskBoardWorkflowStatus::Idle,
        TaskBoardWorkflowStatus::Running,
        TaskBoardWorkflowStatus::Paused,
        TaskBoardWorkflowStatus::Completed,
        TaskBoardWorkflowStatus::Failed,
        TaskBoardWorkflowStatus::Cancelled,
    ]
}

#[cfg(test)]
mod tests {
    use sqlx::query_scalar;

    use super::*;

    #[test]
    fn step_mode_selects_step_admission() {
        assert_eq!(
            desired_mode_for_settings(&TaskBoardOrchestratorSettings {
                step_mode: true,
                ..TaskBoardOrchestratorSettings::default()
            }),
            TaskBoardAutomationDesiredMode::Step
        );
    }

    #[tokio::test]
    async fn legacy_control_does_not_initialize_durable_state() {
        let temp = tempfile::tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
            .await
            .expect("open database");

        let status = start_task_board_orchestrator_with_durable(&db, false)
            .await
            .expect("start legacy orchestrator");

        assert!(status.enabled);
        assert!(status.running);
        let stopped = stop_task_board_orchestrator_with_durable(&db, false)
            .await
            .expect("stop legacy orchestrator");
        assert!(!stopped.enabled);
        assert!(!stopped.running);
        update_running_automation_mode(&db, &TaskBoardOrchestratorSettings::default(), false)
            .await
            .expect("update legacy settings");
        let durable_rows =
            query_scalar::<_, i64>("SELECT COUNT(*) FROM task_board_orchestrator_control")
                .fetch_one(db.pool())
                .await
                .expect("count durable control rows");
        assert_eq!(durable_rows, 0);
    }

    #[tokio::test]
    async fn durable_stop_finishes_immediately_when_no_run_is_active() {
        let temp = tempfile::tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
            .await
            .expect("open database");
        start_task_board_orchestrator_with_durable(&db, true)
            .await
            .expect("start durable orchestrator");

        let status = stop_task_board_orchestrator_with_durable(&db, true)
            .await
            .expect("stop durable orchestrator");

        assert!(!status.enabled);
        assert!(!status.running);
        let control = db
            .task_board_automation_control()
            .await
            .expect("load durable control");
        assert_eq!(
            control.admission_state,
            TaskBoardAutomationAdmissionState::Stopped
        );
    }
}
