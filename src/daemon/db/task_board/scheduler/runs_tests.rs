use std::sync::Arc;

use chrono::Duration;
use sqlx::query_as;
use tokio::sync::Barrier;

use super::test_support::{
    acquire_request, automation_audit_count, database, fail_automation_audit_inserts, instant,
};
use super::{TaskBoardAutomationRunAdmission, TaskBoardAutomationRunFence};
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    TaskBoardAutomationAdmissionState, TaskBoardAutomationDesiredMode,
    TaskBoardAutomationRunOutcome, TaskBoardAutomationRunTrigger,
};

#[tokio::test]
async fn run_lease_serializes_manual_and_scheduled_triggers() {
    let db = database().await;
    let now = instant("2026-07-15T08:00:00Z");
    db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, now)
        .await
        .expect("start automation");
    let manual = acquire(
        &db,
        "run-manual",
        TaskBoardAutomationRunTrigger::Manual,
        now,
    )
    .await;

    let scheduled = db
        .try_acquire_task_board_automation_run(&acquire_request(
            "run-scheduled",
            TaskBoardAutomationRunTrigger::Scheduled,
            now,
        ))
        .await
        .expect("try scheduled run");
    assert_eq!(
        scheduled,
        TaskBoardAutomationRunAdmission::Busy {
            run_id: "run-manual".into()
        }
    );

    db.finalize_task_board_automation_run(
        &manual,
        TaskBoardAutomationRunOutcome::Completed,
        None,
        None,
        now + Duration::seconds(1),
    )
    .await
    .expect("finalize manual run");
    assert!(matches!(
        db.try_acquire_task_board_automation_run(&acquire_request(
            "run-scheduled-next",
            TaskBoardAutomationRunTrigger::Scheduled,
            now + Duration::seconds(2),
        ))
        .await
        .expect("acquire next scheduled run"),
        TaskBoardAutomationRunAdmission::Acquired(_)
    ));
}

#[tokio::test]
async fn concurrent_triggers_admit_exactly_one_run() {
    let db = database().await;
    let now = instant("2026-07-15T08:30:00Z");
    db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, now)
        .await
        .expect("start automation");
    let gate = Arc::new(Barrier::new(2));
    let manual_db = db.clone();
    let manual_gate = Arc::clone(&gate);
    let scheduled_db = db.clone();
    let scheduled_gate = Arc::clone(&gate);

    let (manual, scheduled) = tokio::join!(
        async move {
            manual_gate.wait().await;
            manual_db
                .try_acquire_task_board_automation_run(&acquire_request(
                    "run-concurrent-manual",
                    TaskBoardAutomationRunTrigger::Manual,
                    now,
                ))
                .await
        },
        async move {
            scheduled_gate.wait().await;
            scheduled_db
                .try_acquire_task_board_automation_run(&acquire_request(
                    "run-concurrent-scheduled",
                    TaskBoardAutomationRunTrigger::Scheduled,
                    now,
                ))
                .await
        }
    );
    let outcomes = [
        manual.expect("manual admission"),
        scheduled.expect("scheduled admission"),
    ];
    assert_eq!(
        outcomes
            .iter()
            .filter(|outcome| matches!(outcome, TaskBoardAutomationRunAdmission::Acquired(_)))
            .count(),
        1
    );
    assert_eq!(
        outcomes
            .iter()
            .filter(|outcome| matches!(outcome, TaskBoardAutomationRunAdmission::Busy { .. }))
            .count(),
        1
    );
}

#[tokio::test]
async fn stop_generation_fences_active_run_and_survives_restart() {
    let db = database().await;
    let now = instant("2026-07-15T09:00:00Z");
    db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, now)
        .await
        .expect("start automation");
    let lease = acquire(
        &db,
        "run-fenced",
        TaskBoardAutomationRunTrigger::Scheduled,
        now,
    )
    .await;

    let stopped = db
        .stop_task_board_automation(now + Duration::seconds(1))
        .await
        .expect("stop automation");
    assert_eq!(stopped.desired_mode, TaskBoardAutomationDesiredMode::Off);
    assert_eq!(
        stopped.admission_state,
        TaskBoardAutomationAdmissionState::Draining
    );
    assert_eq!(stopped.stop_generation, 1);
    assert_eq!(
        db.heartbeat_task_board_automation_run(&lease, now + Duration::seconds(2))
            .await
            .expect("heartbeat fenced run"),
        TaskBoardAutomationRunFence::Draining
    );
    assert_eq!(
        db.finalize_task_board_automation_run(
            &lease,
            TaskBoardAutomationRunOutcome::Completed,
            None,
            None,
            now + Duration::seconds(3),
        )
        .await
        .expect("finalize fenced run"),
        TaskBoardAutomationRunOutcome::Cancelled
    );
    assert_eq!(
        db.try_acquire_task_board_automation_run(&acquire_request(
            "run-during-drain",
            TaskBoardAutomationRunTrigger::Manual,
            now + Duration::seconds(4),
        ))
        .await
        .expect("reject run during drain"),
        TaskBoardAutomationRunAdmission::Disabled
    );

    let reopened = AsyncDaemonDb::connect(db.storage_path())
        .await
        .expect("reopen database");
    assert_eq!(
        reopened
            .task_board_automation_control()
            .await
            .expect("load persisted control")
            .stop_generation,
        1
    );
}

#[tokio::test]
async fn expired_run_is_failed_before_recovery_acquires_new_epoch() {
    let db = database().await;
    let now = instant("2026-07-15T10:00:00Z");
    db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, now)
        .await
        .expect("start automation");
    let first = acquire(
        &db,
        "run-expired",
        TaskBoardAutomationRunTrigger::Manual,
        now,
    )
    .await;
    let recovered = acquire(
        &db,
        "run-recovery",
        TaskBoardAutomationRunTrigger::Recovery,
        now + Duration::seconds(31),
    )
    .await;
    assert!(recovered.lease_epoch > first.lease_epoch);
    let row = query_as::<_, (String, String, String)>(
        "SELECT state, outcome, error_kind FROM task_board_orchestrator_runs WHERE run_id = ?1",
    )
    .bind(&first.run_id)
    .fetch_one(db.pool())
    .await
    .expect("load expired run");
    assert_eq!(
        row,
        ("terminal".into(), "failed".into(), "lease_expired".into())
    );
}

#[tokio::test]
async fn stale_run_expiry_publishes_revision_when_replacement_is_disabled() {
    let db = database().await;
    let now = instant("2026-07-15T10:30:00Z");
    db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, now)
        .await
        .expect("start automation");
    acquire(
        &db,
        "run-stale-disabled",
        TaskBoardAutomationRunTrigger::Scheduled,
        now,
    )
    .await;
    db.stop_task_board_automation(now + Duration::seconds(1))
        .await
        .expect("stop automation");
    let revision_before_expiry = db
        .task_board_revision()
        .await
        .expect("revision before expiry");

    assert_eq!(
        db.try_acquire_task_board_automation_run(&acquire_request(
            "run-disabled-replacement",
            TaskBoardAutomationRunTrigger::Scheduled,
            now + Duration::seconds(31),
        ))
        .await
        .expect("attempt disabled replacement"),
        TaskBoardAutomationRunAdmission::Disabled
    );
    assert!(
        db.task_board_revision()
            .await
            .expect("revision after expiry")
            > revision_before_expiry
    );
}

#[tokio::test]
async fn run_acquire_rolls_back_when_audit_insert_fails() {
    let db = database().await;
    let now = instant("2026-07-15T11:00:00Z");
    db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, now)
        .await
        .expect("start automation");
    let revision = db.task_board_revision().await.expect("initial revision");
    fail_automation_audit_inserts(&db).await;

    let error = db
        .try_acquire_task_board_automation_run(&acquire_request(
            "run-audit-acquire-failure",
            TaskBoardAutomationRunTrigger::Manual,
            now,
        ))
        .await
        .expect_err("audit failure must reject acquisition");

    assert!(
        error
            .to_string()
            .contains("simulated automation audit failure")
    );
    assert_eq!(run_count(&db, "run-audit-acquire-failure").await, 0);
    assert_eq!(
        automation_audit_count(&db, "run-audit-acquire-failure").await,
        0
    );
    assert_eq!(
        db.task_board_revision()
            .await
            .expect("revision after failed acquisition"),
        revision
    );
}

#[tokio::test]
async fn run_finalize_rolls_back_when_audit_insert_fails() {
    let db = database().await;
    let now = instant("2026-07-15T11:30:00Z");
    db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, now)
        .await
        .expect("start automation");
    let lease = acquire(
        &db,
        "run-audit-finalize-failure",
        TaskBoardAutomationRunTrigger::Manual,
        now,
    )
    .await;
    fail_automation_audit_inserts(&db).await;

    let error = db
        .finalize_task_board_automation_run(
            &lease,
            TaskBoardAutomationRunOutcome::Completed,
            None,
            None,
            now + Duration::seconds(1),
        )
        .await
        .expect_err("audit failure must roll back finalization");

    assert!(
        error
            .to_string()
            .contains("simulated automation audit failure")
    );
    let row = query_as::<_, (String, Option<String>, i64)>(
        "SELECT state, outcome, revision FROM task_board_orchestrator_runs WHERE run_id = ?1",
    )
    .bind(&lease.run_id)
    .fetch_one(db.pool())
    .await
    .expect("load run after failed finalization");
    assert_eq!(row, ("running".into(), None, 1));
    assert_eq!(automation_audit_count(&db, &lease.run_id).await, 1);
}

async fn acquire(
    db: &AsyncDaemonDb,
    run_id: &str,
    trigger: TaskBoardAutomationRunTrigger,
    now: chrono::DateTime<chrono::Utc>,
) -> super::TaskBoardAutomationRunLease {
    let admission = db
        .try_acquire_task_board_automation_run(&acquire_request(run_id, trigger, now))
        .await
        .expect("acquire automation run");
    let TaskBoardAutomationRunAdmission::Acquired(lease) = admission else {
        panic!("automation run should acquire");
    };
    lease
}

async fn run_count(db: &AsyncDaemonDb, run_id: &str) -> i64 {
    query_as::<_, (i64,)>("SELECT COUNT(*) FROM task_board_orchestrator_runs WHERE run_id = ?1")
        .bind(run_id)
        .fetch_one(db.pool())
        .await
        .expect("count automation runs")
        .0
}
