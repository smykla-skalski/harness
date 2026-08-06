use chrono::Utc;

use crate::daemon::protocol::{
    TaskBoardOrchestratorSettingsResponse, TaskBoardOrchestratorSettingsUpdateRequest,
    TaskBoardOrchestratorStatusResponse,
};
use crate::feature_flags::task_board_automation_v2_enabled_from_env;
use crate::task_board::{
    TaskBoardAutomationAdmissionState, TaskBoardAutomationDesiredMode,
    TaskBoardAutomationWakeEntityKind, TaskBoardAutomationWakePayload,
    TaskBoardAutomationWakeRequest, TaskBoardOrchestratorSettings, TaskBoardOrchestratorState,
    TaskBoardWorkflowExecutionCount, TaskBoardWorkflowStatus,
};
use harness_kernel::errors::CliError;
use harness_kernel::errors::CliErrorKind;

use super::task_board_db::task_board_host_local_db;
use super::task_board_orchestrator_settings::{apply_settings_update, normalize_github_inbox};
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;

pub(crate) async fn task_board_orchestrator_status_db(
    db: &AsyncDaemonDbHandle,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    let state = db.task_board_orchestrator_state().await?;
    status_from_state(db, state, task_board_automation_v2_enabled_from_env()).await
}

pub(crate) async fn start_task_board_orchestrator_db(
    db: &AsyncDaemonDbHandle,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    start_task_board_orchestrator_with_durable(db, task_board_automation_v2_enabled_from_env())
        .await
}

async fn start_task_board_orchestrator_with_durable(
    db: &AsyncDaemonDbHandle,
    durable_enabled: bool,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    if db.automation_kill_switch_engaged().await? {
        return Err(CliErrorKind::invalid_transition("automation kill switch is engaged").into());
    }
    if durable_enabled {
        let settings = db.task_board_orchestrator_settings().await?;
        let desired_mode = desired_mode_for_settings(&settings);
        let now = Utc::now();
        if desired_mode == TaskBoardAutomationDesiredMode::Continuous {
            db.start_task_board_automation_with_wake(
                desired_mode,
                &TaskBoardAutomationWakeRequest {
                    entity_id: Some("automation-control".into()),
                    entity_revision: None,
                    payload: TaskBoardAutomationWakePayload::ledger_changed(
                        TaskBoardAutomationWakeEntityKind::Control,
                    ),
                },
                now,
            )
            .await?;
        } else {
            db.start_task_board_automation(desired_mode, now).await?;
        }
    }
    set_running_intent(db, true, true, durable_enabled).await
}

pub(crate) async fn stop_task_board_orchestrator_db(
    db: &AsyncDaemonDbHandle,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    stop_task_board_orchestrator_with_durable(db, task_board_automation_v2_enabled_from_env()).await
}

pub(crate) async fn enforce_task_board_orchestrator_kill_switch_db(
    db: &AsyncDaemonDbHandle,
) -> Result<(), CliError> {
    let durable_enabled = task_board_automation_v2_enabled_from_env();
    if durable_enabled {
        let control = db.task_board_automation_control().await?;
        if control.desired_mode != TaskBoardAutomationDesiredMode::Off
            || control.admission_state == TaskBoardAutomationAdmissionState::Accepting
        {
            db.stop_task_board_automation(Utc::now()).await?;
        }
        db.finish_task_board_automation_drain_if_idle(Utc::now())
            .await?;
    }
    let mut state = db.task_board_orchestrator_state().await?;
    if state.enabled || state.running {
        state.enabled = false;
        state.running = false;
        db.replace_task_board_orchestrator_state(&state).await?;
    }
    Ok(())
}

async fn stop_task_board_orchestrator_with_durable(
    db: &AsyncDaemonDbHandle,
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
    db: &AsyncDaemonDbHandle,
) -> Result<TaskBoardOrchestratorSettingsResponse, CliError> {
    db.task_board_orchestrator_settings().await
}

pub(crate) async fn update_task_board_orchestrator_settings_db(
    db: &AsyncDaemonDbHandle,
    request: &TaskBoardOrchestratorSettingsUpdateRequest,
) -> Result<TaskBoardOrchestratorSettingsResponse, CliError> {
    let mut settings = db.task_board_orchestrator_settings().await?;
    apply_settings_update(&mut settings, request);
    settings.github_inbox = normalize_github_inbox(&settings.github_inbox)?;
    replace_orchestrator_settings_with_durable(
        db,
        &settings,
        task_board_automation_v2_enabled_from_env(),
    )
    .await?;
    Ok(settings)
}

async fn replace_orchestrator_settings_with_durable(
    db: &AsyncDaemonDbHandle,
    settings: &TaskBoardOrchestratorSettings,
    durable_enabled: bool,
) -> Result<i64, CliError> {
    if !durable_enabled {
        return db.replace_task_board_orchestrator_settings(settings).await;
    }
    db.replace_task_board_orchestrator_settings_for_automation(
        settings,
        desired_mode_for_settings(settings),
        Utc::now(),
    )
    .await
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
    db: &AsyncDaemonDbHandle,
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
    db: &AsyncDaemonDbHandle,
    state: TaskBoardOrchestratorState,
    durable_enabled: bool,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    let settings = db.task_board_orchestrator_settings().await?;
    let held_dispatches = db.held_task_board_dispatch_summary().await?;
    let machine = task_board_host_local_db(db).await.ok();
    let repository_scope =
        super::task_board_repository_scope::TaskBoardRepositoryScope::load_with_settings(
            db, &settings,
        )
        .await?;
    let items = repository_scope.filter_items(db.list_task_board_items(None).await?);
    let items = items.iter().filter(|item| {
        machine
            .as_ref()
            .is_none_or(|machine| machine.accepts_any(&item.target_project_types))
    });
    let workflow_execution_counts = TaskBoardWorkflowStatus::all()
        .iter()
        .copied()
        .filter_map(|status| {
            let count = items
                .clone()
                .filter(|item| item.workflow.status == status)
                .count();
            (count > 0).then_some(TaskBoardWorkflowExecutionCount { status, count })
        })
        .collect();
    let automation = if durable_enabled {
        Some(super::task_board_automation_snapshot(db).await?)
    } else {
        None
    };
    let enabled = automation.as_ref().map_or(state.enabled, |snapshot| {
        snapshot.desired_mode != TaskBoardAutomationDesiredMode::Off
    });
    let running = automation.as_ref().map_or(state.running, |snapshot| {
        snapshot.admission_state == TaskBoardAutomationAdmissionState::Accepting
    });
    Ok(TaskBoardOrchestratorStatusResponse {
        enabled,
        running,
        step_mode: settings.step_mode,
        held_dispatches,
        current_tick: state.current_tick,
        last_run: state.last_run,
        workflow_execution_counts,
        automation,
        settings,
    })
}

#[cfg(test)]
mod tests;
