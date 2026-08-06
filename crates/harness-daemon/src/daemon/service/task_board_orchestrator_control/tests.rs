use sqlx::query_scalar;

use super::*;
use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardAutomationRunAdmission, TaskBoardRunAcquireRequest,
};
use crate::daemon::db_open::AsyncDaemonDbConnect;
use crate::task_board::{
    TaskBoardAutomationEffectiveState, TaskBoardAutomationRunTrigger, TaskBoardAutomationScope,
};

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
    let db = AsyncDaemonDbHandle(db);

    let status = start_task_board_orchestrator_with_durable(&db, false)
        .await
        .expect("start legacy orchestrator");

    assert!(status.enabled);
    assert!(status.running);
    assert!(status.automation.is_none());
    let stopped = stop_task_board_orchestrator_with_durable(&db, false)
        .await
        .expect("stop legacy orchestrator");
    assert!(!stopped.enabled);
    assert!(!stopped.running);
    assert!(stopped.automation.is_none());
    replace_orchestrator_settings_with_durable(
        &db,
        &TaskBoardOrchestratorSettings::default(),
        false,
    )
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
async fn status_workflow_counts_follow_configured_repository_scope() {
    let temp = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("open database");
    let db = AsyncDaemonDbHandle(db);
    let mut settings = TaskBoardOrchestratorSettings::default();
    settings.github_inbox.repositories = vec!["smykla-skalski/harness".into()];
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("save repository scope");

    for (id, repository, workflow_status) in [
        (
            "allowed",
            Some("smykla-skalski/harness"),
            TaskBoardWorkflowStatus::Idle,
        ),
        (
            "disabled",
            Some("example/disabled"),
            TaskBoardWorkflowStatus::Paused,
        ),
        ("local", None, TaskBoardWorkflowStatus::Paused),
    ] {
        let mut item = crate::task_board::TaskBoardItem::new(
            id.into(),
            id.into(),
            String::new(),
            "2026-08-03T10:00:00Z".into(),
        );
        item.execution_repository = repository.map(Into::into);
        item.workflow.status = workflow_status;
        db.create_task_board_item(item)
            .await
            .expect("seed workflow item");
    }

    let status = status_from_state(
        &db,
        db.task_board_orchestrator_state()
            .await
            .expect("load orchestrator state"),
        false,
    )
    .await
    .expect("load orchestrator status");

    assert_eq!(
        status.workflow_execution_counts,
        [
            TaskBoardWorkflowExecutionCount {
                status: TaskBoardWorkflowStatus::Idle,
                count: 1,
            },
            TaskBoardWorkflowExecutionCount {
                status: TaskBoardWorkflowStatus::Paused,
                count: 1,
            },
        ]
    );
}

#[tokio::test]
async fn durable_continuous_start_enqueues_a_control_wake() {
    let temp = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("open database");
    let db = AsyncDaemonDbHandle(db);

    start_task_board_orchestrator_with_durable(&db, true)
        .await
        .expect("start durable orchestrator");

    let wakes = db
        .pending_task_board_automation_wake_events(10)
        .await
        .expect("load control wake");
    assert_eq!(wakes.len(), 1);
    assert_eq!(wakes[0].entity_id.as_deref(), Some("automation-control"));
    assert!(matches!(
        wakes[0].payload,
        TaskBoardAutomationWakePayload::LedgerChanged(ref payload)
            if payload.entity_kind == TaskBoardAutomationWakeEntityKind::Control
    ));
}

#[tokio::test]
async fn durable_step_start_does_not_enqueue_an_automatic_wake() {
    let temp = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("open database");
    let db = AsyncDaemonDbHandle(db);
    db.replace_task_board_orchestrator_settings(&TaskBoardOrchestratorSettings {
        step_mode: true,
        ..TaskBoardOrchestratorSettings::default()
    })
    .await
    .expect("save step settings");

    start_task_board_orchestrator_with_durable(&db, true)
        .await
        .expect("start step orchestrator");

    assert!(
        db.pending_task_board_automation_wake_events(10)
            .await
            .expect("load step wakes")
            .is_empty()
    );
}

#[tokio::test]
async fn running_continuous_settings_update_enqueues_its_revision() {
    let temp = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("open database");
    let db = AsyncDaemonDbHandle(db);
    db.replace_task_board_orchestrator_state(&TaskBoardOrchestratorState::default())
        .await
        .expect("advance unrelated change revision");
    db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, Utc::now())
        .await
        .expect("start durable automation");

    let revision = replace_orchestrator_settings_with_durable(
        &db,
        &TaskBoardOrchestratorSettings::default(),
        true,
    )
    .await
    .expect("update running settings");

    let wakes = db
        .pending_task_board_automation_wake_events(10)
        .await
        .expect("load settings wake");
    assert_eq!(wakes.len(), 1);
    assert_eq!(wakes[0].entity_id.as_deref(), Some("automation-settings"));
    assert_eq!(wakes[0].entity_revision, u64::try_from(revision).ok());
    let change_revision = query_scalar::<_, i64>(
        "SELECT change_seq FROM change_tracking WHERE scope = 'task_board:orchestrator'",
    )
    .fetch_one(db.pool())
    .await
    .expect("read orchestrator change revision");
    assert!(change_revision > revision);
    assert!(matches!(
        wakes[0].payload,
        TaskBoardAutomationWakePayload::LedgerChanged(ref payload)
            if payload.entity_kind == TaskBoardAutomationWakeEntityKind::Settings
    ));
}

#[tokio::test]
async fn durable_stop_finishes_immediately_when_no_run_is_active() {
    let temp = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("open database");
    let db = AsyncDaemonDbHandle(db);
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

#[tokio::test]
async fn durable_status_is_not_running_while_control_is_draining() {
    let temp = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("open database");
    let db = AsyncDaemonDbHandle(db);
    let now = Utc::now();
    db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, now)
        .await
        .expect("start automation");
    let admission = db
        .try_acquire_task_board_automation_run(&TaskBoardRunAcquireRequest {
            run_id: "run-status-draining".into(),
            trigger: TaskBoardAutomationRunTrigger::Scheduled,
            actor: Some("scheduler-test".into()),
            dry_run: false,
            scope: TaskBoardAutomationScope::default(),
            lease_owner: "scheduler-test-owner".into(),
            now,
        })
        .await
        .expect("acquire active run");
    assert!(matches!(
        admission,
        TaskBoardAutomationRunAdmission::Acquired(_)
    ));
    db.stop_task_board_automation(Utc::now())
        .await
        .expect("start draining");
    let control_before_status = db
        .task_board_automation_control()
        .await
        .expect("load draining control");

    let status = status_from_state(
        &db,
        db.task_board_orchestrator_state()
            .await
            .expect("load orchestrator state"),
        true,
    )
    .await
    .expect("load durable status");

    assert!(!status.enabled);
    assert!(!status.running);
    let snapshot = status.automation.expect("durable automation snapshot");
    assert_eq!(
        snapshot.admission_state,
        TaskBoardAutomationAdmissionState::Draining
    );
    assert_eq!(
        snapshot.effective_state,
        TaskBoardAutomationEffectiveState::Stopping
    );
    assert_eq!(
        db.task_board_automation_control()
            .await
            .expect("reload draining control"),
        control_before_status,
        "status reads must not finish or otherwise mutate the drain"
    );
}
