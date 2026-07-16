use chrono::Duration;

use super::test_support::{database, instant};
use crate::task_board::{TaskBoardAutomationAdmissionState, TaskBoardAutomationDesiredMode};

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
