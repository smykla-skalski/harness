use chrono::{Duration, Utc};
use sqlx::{query, query_as};

use super::*;
use crate::daemon::db::{TaskBoardAutomationRunAdmission, TaskBoardRunAcquireRequest};
use crate::task_board::{
    TaskBoardAutomationScope, TaskBoardAutomationWakeEvent, TaskBoardAutomationWakePayload,
};

async fn database() -> AsyncDaemonDb {
    let temp = tempfile::tempdir().expect("tempdir");
    AsyncDaemonDb::connect(&temp.keep().join("harness.db"))
        .await
        .expect("open database")
}

async fn acquire_run(db: &AsyncDaemonDb, run_id: &str, now: chrono::DateTime<Utc>) {
    db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, now)
        .await
        .expect("start automation");
    let admission = db
        .try_acquire_task_board_automation_run(&TaskBoardRunAcquireRequest {
            run_id: run_id.into(),
            trigger: TaskBoardAutomationRunTrigger::Scheduled,
            actor: Some("scheduler-test".into()),
            dry_run: false,
            scope: TaskBoardAutomationScope::default(),
            lease_owner: "scheduler-test-owner".into(),
            now,
        })
        .await
        .expect("acquire run");
    assert!(matches!(
        admission,
        TaskBoardAutomationRunAdmission::Acquired(_)
    ));
}

async fn expire_run(db: &AsyncDaemonDb, run_id: &str, now: chrono::DateTime<Utc>) {
    query("UPDATE task_board_orchestrator_runs SET lease_expires_at = ?2 WHERE run_id = ?1")
        .bind(run_id)
        .bind((now - Duration::seconds(1)).to_rfc3339())
        .execute(db.pool())
        .await
        .expect("expire run");
}

#[tokio::test]
async fn tick_maintenance_finishes_a_dropped_stop_without_restart() {
    let db = database().await;
    let now = Utc::now();
    acquire_run(&db, "run-dropped-stop", now).await;
    db.stop_task_board_automation(now + Duration::seconds(1))
        .await
        .expect("stop automation");
    expire_run(&db, "run-dropped-stop", now).await;

    maintain_automation_tick(&db)
        .await
        .expect("maintain stopped automation");

    let run = query_as::<_, (String, String)>(
        "SELECT state, outcome FROM task_board_orchestrator_runs WHERE run_id = ?1",
    )
    .bind("run-dropped-stop")
    .fetch_one(db.pool())
    .await
    .expect("load recovered run");
    assert_eq!(run, ("terminal".into(), "cancelled".into()));
    let control = db
        .task_board_automation_control()
        .await
        .expect("load stopped control");
    assert_eq!(control.desired_mode, TaskBoardAutomationDesiredMode::Off);
    assert_eq!(
        control.admission_state,
        TaskBoardAutomationAdmissionState::Stopped
    );
}

#[tokio::test]
async fn tick_maintenance_enqueues_lease_expired_recovery() {
    let db = database().await;
    let now = Utc::now();
    acquire_run(&db, "run-dropped-continuous", now).await;
    expire_run(&db, "run-dropped-continuous", now).await;

    maintain_automation_tick(&db)
        .await
        .expect("maintain continuous automation");

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
