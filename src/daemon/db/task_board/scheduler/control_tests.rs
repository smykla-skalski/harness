use chrono::Duration;
use sqlx::{query, query_scalar};

use super::test_support::{database, instant};
use crate::task_board::{
    TaskBoardAutomationAdmissionState, TaskBoardAutomationDesiredMode,
    TaskBoardAutomationWakeEntityKind, TaskBoardAutomationWakePayload,
    TaskBoardAutomationWakeRequest, TaskBoardOrchestratorSettings,
};

#[tokio::test]
async fn control_defaults_without_persisted_intent() {
    let db = database().await;

    let control = db
        .task_board_automation_control()
        .await
        .expect("load default control");

    assert_eq!(control.desired_mode, TaskBoardAutomationDesiredMode::Off);
    assert_eq!(
        control.admission_state,
        TaskBoardAutomationAdmissionState::Stopped
    );
    assert_eq!(control.stop_generation, 0);
    assert!(control.updated_at.is_empty());
}

#[tokio::test]
async fn legacy_intent_initializes_only_pristine_control() {
    let db = database().await;
    let now = instant("2026-07-15T07:00:00Z");

    let initialized = db
        .initialize_task_board_automation_control_from_legacy_intent(
            TaskBoardAutomationDesiredMode::Continuous,
            now,
        )
        .await
        .expect("initialize legacy intent");
    assert_eq!(
        initialized.desired_mode,
        TaskBoardAutomationDesiredMode::Continuous
    );
    assert_eq!(
        initialized.admission_state,
        TaskBoardAutomationAdmissionState::Accepting
    );

    let stopped = db
        .stop_task_board_automation(now + Duration::seconds(1))
        .await
        .expect("stop initialized control");
    assert_eq!(stopped.stop_generation, 1);
    let retained = db
        .initialize_task_board_automation_control_from_legacy_intent(
            TaskBoardAutomationDesiredMode::Step,
            now + Duration::seconds(2),
        )
        .await
        .expect("retain explicit control");
    assert_eq!(retained.desired_mode, TaskBoardAutomationDesiredMode::Off);
    assert_eq!(
        retained.admission_state,
        TaskBoardAutomationAdmissionState::Draining
    );
    assert_eq!(retained.stop_generation, 1);
}

#[tokio::test]
async fn idle_drain_transitions_to_stopped_once() {
    let db = database().await;
    let now = instant("2026-07-15T07:30:00Z");

    db.stop_task_board_automation(now)
        .await
        .expect("start drain");
    let revision_before = db
        .task_board_revision()
        .await
        .expect("revision before drain completion");
    let stopped = db
        .finish_task_board_automation_drain_if_idle(now + Duration::seconds(1))
        .await
        .expect("finish idle drain");
    assert_eq!(
        stopped.admission_state,
        TaskBoardAutomationAdmissionState::Stopped
    );
    let revision_after = db
        .task_board_revision()
        .await
        .expect("revision after drain completion");
    assert!(revision_after > revision_before);

    db.finish_task_board_automation_drain_if_idle(now + Duration::seconds(2))
        .await
        .expect("repeat drain completion");
    assert_eq!(
        db.task_board_revision()
            .await
            .expect("revision after repeated completion"),
        revision_after
    );
}

#[tokio::test]
async fn start_and_control_wake_roll_back_together() {
    let db = database().await;
    query("DROP TABLE task_board_orchestrator_wake_events")
        .execute(db.pool())
        .await
        .expect("drop wake table");

    db.start_task_board_automation_with_wake(
        TaskBoardAutomationDesiredMode::Continuous,
        &TaskBoardAutomationWakeRequest {
            entity_id: Some("automation-control".into()),
            entity_revision: None,
            payload: TaskBoardAutomationWakePayload::ledger_changed(
                TaskBoardAutomationWakeEntityKind::Control,
            ),
        },
        instant("2026-07-15T08:00:00Z"),
    )
    .await
    .expect_err("missing wake table must fail start");

    let control_rows =
        query_scalar::<_, i64>("SELECT COUNT(*) FROM task_board_orchestrator_control")
            .fetch_one(db.pool())
            .await
            .expect("count control rows");
    assert_eq!(control_rows, 0);
}

#[tokio::test]
async fn settings_control_and_wake_roll_back_together() {
    let db = database().await;
    let baseline = TaskBoardOrchestratorSettings::default();
    db.replace_task_board_orchestrator_settings(&baseline)
        .await
        .expect("save baseline settings");
    let now = instant("2026-07-15T08:30:00Z");
    let control = db
        .start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, now)
        .await
        .expect("start automation");
    query("DROP TABLE task_board_orchestrator_wake_events")
        .execute(db.pool())
        .await
        .expect("drop wake table");
    let updated = TaskBoardOrchestratorSettings {
        dry_run_default: !baseline.dry_run_default,
        ..baseline.clone()
    };

    db.replace_task_board_orchestrator_settings_for_automation(
        &updated,
        TaskBoardAutomationDesiredMode::Continuous,
        now + Duration::seconds(1),
    )
    .await
    .expect_err("missing wake table must fail settings update");

    assert_eq!(
        db.task_board_orchestrator_settings()
            .await
            .expect("reload settings"),
        baseline
    );
    assert_eq!(
        db.task_board_automation_control()
            .await
            .expect("reload control"),
        control
    );
}
