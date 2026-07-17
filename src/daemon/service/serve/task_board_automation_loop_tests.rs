use chrono::{Duration as ChronoDuration, Utc};
use sqlx::{query, query_as};

use super::*;
use crate::daemon::db::{TaskBoardAutomationRunAdmission, TaskBoardRunAcquireRequest};
use crate::task_board::{
    TaskBoardAutomationScope, TaskBoardAutomationWakePayload, TaskBoardAutomationWakeRequest,
    TaskBoardItem,
};

async fn database() -> AsyncDaemonDb {
    let temp = tempfile::tempdir().expect("tempdir");
    AsyncDaemonDb::connect(&temp.keep().join("harness.db"))
        .await
        .expect("open database")
}

async fn start_automation(db: &AsyncDaemonDb) {
    db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, Utc::now())
        .await
        .expect("start automation");
}

async fn enqueue_item_wake(
    db: &AsyncDaemonDb,
    entity_id: &str,
    revision: u64,
) -> TaskBoardAutomationWakeEvent {
    db.enqueue_task_board_automation_wake_event(
        &TaskBoardAutomationWakeRequest {
            entity_id: Some(entity_id.into()),
            entity_revision: Some(revision),
            payload: TaskBoardAutomationWakePayload::ledger_changed(
                TaskBoardAutomationWakeEntityKind::Item,
            ),
        },
        Utc::now(),
    )
    .await
    .expect("enqueue item wake")
}

#[test]
fn only_current_coordinator_inputs_map_to_change_wakes() {
    assert_eq!(
        wake_entity_kind("task_board:items"),
        Some(TaskBoardAutomationWakeEntityKind::Item)
    );
    assert_eq!(
        wake_entity_kind("task_board:runtime_config"),
        Some(TaskBoardAutomationWakeEntityKind::Settings)
    );
    assert_eq!(
        wake_entity_kind("task_board:policy_pipeline"),
        Some(TaskBoardAutomationWakeEntityKind::Policy)
    );
    assert_eq!(wake_entity_kind("task_board:orchestrator"), None);
    assert_eq!(wake_entity_kind("task_board:machines"), None);
    assert_eq!(wake_entity_kind("task_board:policy_runtime"), None);
}

#[test]
fn recovery_wakes_take_precedence_over_ledger_wakes() {
    let ledger = TaskBoardAutomationWakeEvent {
        sequence: 1,
        entity_id: Some("task_board:items".into()),
        entity_revision: Some(1),
        payload: TaskBoardAutomationWakePayload::ledger_changed(
            TaskBoardAutomationWakeEntityKind::Item,
        ),
        created_at: "2026-07-17T10:00:00Z".into(),
    };
    let recovery = TaskBoardAutomationWakeEvent {
        sequence: 2,
        entity_id: None,
        entity_revision: None,
        payload: TaskBoardAutomationWakePayload::recovery(
            TaskBoardAutomationWakeRecoveryReason::Startup,
        ),
        created_at: "2026-07-17T10:00:01Z".into(),
    };

    assert_eq!(
        trigger_for_wakes(&[ledger, recovery]),
        TaskBoardAutomationRunTrigger::Recovery
    );
}

#[test]
fn retry_delay_is_exponential_and_bounded() {
    let retry = TaskBoardAutomationRetrySettings {
        max_attempts: 4,
        base_delay_seconds: 2,
        multiplier: 3,
        max_delay_seconds: 20,
        deterministic_jitter_percent: 0,
    };

    assert_eq!(retry_delay(&retry, 1), Duration::from_secs(2));
    assert_eq!(retry_delay(&retry, 2), Duration::from_secs(6));
    assert_eq!(retry_delay(&retry, 3), Duration::from_secs(18));
    assert_eq!(retry_delay(&retry, 4), Duration::from_secs(20));
    assert_eq!(retry_delay(&retry, 10), Duration::from_secs(20));

    let unbounded = TaskBoardAutomationRetrySettings {
        max_attempts: u32::MAX,
        base_delay_seconds: 1,
        multiplier: 2,
        max_delay_seconds: u64::MAX,
        deterministic_jitter_percent: 0,
    };
    assert_eq!(
        retry_delay(&unbounded, u32::MAX),
        Duration::from_secs(MAX_COORDINATOR_BACKOFF_SECONDS)
    );
}

#[test]
fn retry_backoff_blocks_an_already_due_interval() {
    let mut loop_state = AutomationLoopState::new(0);
    loop_state.last_reconciliation = Instant::now() - Duration::from_secs(60);
    loop_state.retry_not_before = Some(Instant::now() + Duration::from_secs(60));

    assert!(loop_state.last_reconciliation.elapsed() >= Duration::from_secs(1));
    assert!(loop_state.is_backing_off());
}

#[tokio::test]
async fn startup_bridges_running_legacy_intent_and_enqueues_recovery() {
    let db = database().await;
    db.replace_task_board_orchestrator_state(&TaskBoardOrchestratorState {
        enabled: true,
        running: true,
        ..TaskBoardOrchestratorState::default()
    })
    .await
    .expect("save running legacy intent");

    initialize_automation(&db)
        .await
        .expect("initialize automation");

    let control = db
        .task_board_automation_control()
        .await
        .expect("load control");
    assert_eq!(
        control.desired_mode,
        TaskBoardAutomationDesiredMode::Continuous
    );
    assert_eq!(
        control.admission_state,
        TaskBoardAutomationAdmissionState::Accepting
    );
    let wakes = db
        .pending_task_board_automation_wake_events(10)
        .await
        .expect("load startup wakes");
    assert_eq!(wakes.len(), 1);
    assert_eq!(
        wakes[0].payload.cause(),
        TaskBoardAutomationWakeCause::Recovery
    );
}

#[tokio::test]
async fn startup_bridges_legacy_step_without_an_automatic_recovery_wake() {
    let db = database().await;
    db.replace_task_board_orchestrator_state(&TaskBoardOrchestratorState {
        enabled: true,
        running: true,
        ..TaskBoardOrchestratorState::default()
    })
    .await
    .expect("save running legacy intent");
    db.replace_task_board_orchestrator_settings(&TaskBoardOrchestratorSettings {
        step_mode: true,
        ..TaskBoardOrchestratorSettings::default()
    })
    .await
    .expect("save step settings");

    initialize_automation(&db)
        .await
        .expect("initialize step automation");

    let control = db
        .task_board_automation_control()
        .await
        .expect("load step control");
    assert_eq!(control.desired_mode, TaskBoardAutomationDesiredMode::Step);
    assert_eq!(
        control.admission_state,
        TaskBoardAutomationAdmissionState::Accepting
    );
    assert!(
        db.pending_task_board_automation_wake_events(10)
            .await
            .expect("load step wakes")
            .is_empty()
    );
}

#[tokio::test]
async fn startup_preserves_an_explicit_durable_stop() {
    let db = database().await;
    db.replace_task_board_orchestrator_state(&TaskBoardOrchestratorState {
        enabled: true,
        running: true,
        ..TaskBoardOrchestratorState::default()
    })
    .await
    .expect("save running legacy intent");
    start_automation(&db).await;
    db.stop_task_board_automation(Utc::now())
        .await
        .expect("stop automation");
    db.finish_task_board_automation_drain_if_idle(Utc::now())
        .await
        .expect("finish stop");

    initialize_automation(&db)
        .await
        .expect("reinitialize automation");

    let control = db
        .task_board_automation_control()
        .await
        .expect("load stopped control");
    assert_eq!(control.desired_mode, TaskBoardAutomationDesiredMode::Off);
    assert_eq!(
        control.admission_state,
        TaskBoardAutomationAdmissionState::Stopped
    );
    assert!(
        db.pending_task_board_automation_wake_events(10)
            .await
            .expect("load stopped wakes")
            .is_empty()
    );
}

#[tokio::test]
async fn startup_recovery_marks_expired_runs_and_uses_lease_expired_wake() {
    let db = database().await;
    let started_at = Utc::now();
    start_automation(&db).await;
    let admission = db
        .try_acquire_task_board_automation_run(&TaskBoardRunAcquireRequest {
            run_id: "run-expired-startup".into(),
            trigger: TaskBoardAutomationRunTrigger::Scheduled,
            actor: Some("scheduler-test".into()),
            dry_run: false,
            scope: TaskBoardAutomationScope::default(),
            lease_owner: "scheduler-test-owner".into(),
            now: started_at,
        })
        .await
        .expect("acquire run");
    assert!(matches!(
        admission,
        TaskBoardAutomationRunAdmission::Acquired(_)
    ));
    query("UPDATE task_board_orchestrator_runs SET lease_expires_at = ?2 WHERE run_id = ?1")
        .bind("run-expired-startup")
        .bind((started_at - ChronoDuration::seconds(1)).to_rfc3339())
        .execute(db.pool())
        .await
        .expect("expire run");

    initialize_automation(&db)
        .await
        .expect("recover automation");

    let run = query_as::<_, (String, String)>(
        "SELECT state, outcome FROM task_board_orchestrator_runs WHERE run_id = ?1",
    )
    .bind("run-expired-startup")
    .fetch_one(db.pool())
    .await
    .expect("load recovered run");
    assert_eq!(run, ("terminal".into(), "failed".into()));
    let wakes = db
        .pending_task_board_automation_wake_events(10)
        .await
        .expect("load recovery wake");
    assert!(matches!(
        wakes.as_slice(),
        [TaskBoardAutomationWakeEvent {
            payload: TaskBoardAutomationWakePayload::Recovery(value),
            ..
        }] if value.reason == TaskBoardAutomationWakeRecoveryReason::LeaseExpired
    ));
}

#[tokio::test]
async fn stopped_automation_advances_the_cursor_without_wake_churn() {
    let db = database().await;
    let mut change_sequence = db
        .current_change_sequence()
        .await
        .expect("initial sequence");
    db.create_task_board_item(TaskBoardItem::new(
        "task-stopped-change".into(),
        "Stopped change".into(),
        "Body".into(),
        "2026-07-17T10:00:00Z".into(),
    ))
    .await
    .expect("create item");

    assert!(
        !capture_automatic_change_wakes(&db, &mut change_sequence)
            .await
            .expect("capture stopped changes")
    );
    assert_eq!(
        change_sequence,
        db.current_change_sequence()
            .await
            .expect("current sequence")
    );
    assert!(
        db.pending_task_board_automation_wake_events(10)
            .await
            .expect("load stopped wakes")
            .is_empty()
    );
}

#[tokio::test]
async fn relevant_cursor_advances_only_after_durable_enqueue() {
    let db = database().await;
    start_automation(&db).await;
    let mut change_sequence = db
        .current_change_sequence()
        .await
        .expect("initial sequence");
    db.create_task_board_item(TaskBoardItem::new(
        "task-enqueue-failure".into(),
        "Enqueue failure".into(),
        "Body".into(),
        "2026-07-17T10:00:00Z".into(),
    ))
    .await
    .expect("create item");
    let initial = change_sequence;
    query("DROP TABLE task_board_orchestrator_wake_events")
        .execute(db.pool())
        .await
        .expect("remove wake storage");

    enqueue_change_wakes(&db, &mut change_sequence)
        .await
        .expect_err("enqueue must fail closed");

    assert_eq!(change_sequence, initial);
}

#[tokio::test]
async fn finalized_success_acknowledges_only_the_pre_run_batch() {
    let db = database().await;
    start_automation(&db).await;
    enqueue_item_wake(&db, "task-before-run", 1).await;
    let wakes = db
        .pending_task_board_automation_wake_events(10)
        .await
        .expect("load pre-run wakes");

    process_wake_batch(&db, &wakes, |_| async {
        enqueue_item_wake(&db, "task-during-run", 2).await;
        Ok(())
    })
    .await
    .expect("acknowledge finalized run");

    let pending = db
        .pending_task_board_automation_wake_events(10)
        .await
        .expect("load remaining wakes");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].entity_id.as_deref(), Some("task-during-run"));
}

#[tokio::test]
async fn finalized_partial_acknowledges_the_batch_for_provider_backoff_to_own_retry() {
    let db = database().await;
    start_automation(&db).await;
    enqueue_item_wake(&db, "task-partial-run", 1).await;
    let wakes = db
        .pending_task_board_automation_wake_events(10)
        .await
        .expect("load partial-run wakes");

    // The production route represents a finalized Partial as `Ok`; provider
    // backoff and the interval fallback own any later reconciliation.
    process_wake_batch(&db, &wakes, |_| async { Ok(()) })
        .await
        .expect("acknowledge finalized partial run");

    assert!(
        db.pending_task_board_automation_wake_events(10)
            .await
            .expect("load acknowledged wakes")
            .is_empty()
    );
}

#[tokio::test]
async fn busy_error_or_cancellation_keeps_the_batch_pending() {
    let db = database().await;
    start_automation(&db).await;
    enqueue_item_wake(&db, "task-failed-run", 1).await;
    let wakes = db
        .pending_task_board_automation_wake_events(10)
        .await
        .expect("load wakes");

    process_wake_batch(&db, &wakes, |_| async {
        Err::<(), CliError>(CliErrorKind::session_agent_conflict("run is busy").into())
    })
    .await
    .expect_err("failed run must retain wakes");

    assert_eq!(
        db.pending_task_board_automation_wake_events(10)
            .await
            .expect("load retained wakes")
            .len(),
        1
    );
}

#[tokio::test]
async fn acknowledgement_failure_keeps_the_remaining_batch_pending() {
    let db = database().await;
    start_automation(&db).await;
    let removed = enqueue_item_wake(&db, "task-removed-before-ack", 1).await;
    enqueue_item_wake(&db, "task-still-pending", 2).await;
    let wakes = db
        .pending_task_board_automation_wake_events(10)
        .await
        .expect("load wakes");

    process_wake_batch(&db, &wakes, |_| async {
        query("DELETE FROM task_board_orchestrator_wake_events WHERE sequence = ?1")
            .bind(i64::try_from(removed.sequence).expect("stored sequence"))
            .execute(db.pool())
            .await
            .expect("simulate acknowledgement race");
        Ok(())
    })
    .await
    .expect_err("incomplete acknowledgement must fail");

    let pending = db
        .pending_task_board_automation_wake_events(10)
        .await
        .expect("load pending batch");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].entity_id.as_deref(), Some("task-still-pending"));
}
