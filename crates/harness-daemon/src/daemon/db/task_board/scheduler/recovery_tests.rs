use chrono::Duration;
use sqlx::{query, query_as};

use super::TaskBoardAutomationRunAdmission;
use super::test_support::{
    acquire_request, automation_audit_count, database, fail_automation_audit_inserts, instant,
};
use crate::task_board::{TaskBoardAutomationDesiredMode, TaskBoardAutomationRunTrigger};

#[tokio::test]
async fn startup_recovery_expires_stale_run_and_publishes_revision() {
    let db = database().await;
    let started_at = instant("2026-07-15T15:00:00.900Z");
    db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, started_at)
        .await
        .expect("start automation");
    let admission = db
        .try_acquire_task_board_automation_run(&acquire_request(
            "run-startup-stale",
            TaskBoardAutomationRunTrigger::Scheduled,
            started_at,
        ))
        .await
        .expect("acquire stale run");
    assert!(matches!(
        admission,
        TaskBoardAutomationRunAdmission::Acquired(_)
    ));
    let revision_before = db
        .task_board_revision()
        .await
        .expect("revision before recovery");
    let recovered_at = started_at + Duration::seconds(30);

    assert_eq!(
        db.recover_stale_task_board_automation_runs(started_at + Duration::milliseconds(29_200))
            .await
            .expect("recover before fractional expiry"),
        0
    );
    assert_eq!(active_run_count(&db).await, 1);
    assert_eq!(
        db.task_board_revision()
            .await
            .expect("revision before fractional expiry"),
        revision_before
    );

    assert_eq!(
        db.recover_stale_task_board_automation_runs(recovered_at)
            .await
            .expect("recover stale runs"),
        1
    );
    assert_eq!(active_run_count(&db).await, 0);
    let row = query_as::<_, (String, String, String, String)>(
        "SELECT state, outcome, error_kind, completed_at
         FROM task_board_orchestrator_runs WHERE run_id = 'run-startup-stale'",
    )
    .fetch_one(db.pool())
    .await
    .expect("load recovered run");
    assert_eq!(
        row,
        (
            "terminal".into(),
            "failed".into(),
            "lease_expired".into(),
            "2026-07-15T15:00:30.900+00:00".into(),
        )
    );
    let revision_after = db
        .task_board_revision()
        .await
        .expect("revision after recovery");
    assert!(revision_after > revision_before);
    assert_eq!(run_count(&db).await, 1, "recovery starts no replacement");
    assert_eq!(automation_audit_count(&db, "run-startup-stale").await, 2);

    assert_eq!(
        db.recover_stale_task_board_automation_runs(recovered_at + Duration::seconds(1))
            .await
            .expect("repeat recovery"),
        0
    );
    assert_eq!(
        db.task_board_revision()
            .await
            .expect("revision after repeat recovery"),
        revision_after
    );
}

#[tokio::test]
async fn stale_cancelling_run_is_cancelled_and_audited() {
    let db = database().await;
    let started_at = instant("2026-07-15T16:00:00Z");
    db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, started_at)
        .await
        .expect("start automation");
    db.try_acquire_task_board_automation_run(&acquire_request(
        "run-stale-cancelling",
        TaskBoardAutomationRunTrigger::Scheduled,
        started_at,
    ))
    .await
    .expect("acquire run");
    db.stop_task_board_automation(started_at + Duration::seconds(1))
        .await
        .expect("stop automation");

    assert_eq!(
        db.recover_stale_task_board_automation_runs(started_at + Duration::seconds(30))
            .await
            .expect("recover cancelling run"),
        1
    );

    let row = query_as::<_, (String, String)>(
        "SELECT state, outcome FROM task_board_orchestrator_runs WHERE run_id = ?1",
    )
    .bind("run-stale-cancelling")
    .fetch_one(db.pool())
    .await
    .expect("load cancelled run");
    assert_eq!(row, ("terminal".into(), "cancelled".into()));
    assert_eq!(
        terminal_audit_outcome(&db, "run-stale-cancelling").await,
        "cancelled"
    );
}

#[tokio::test]
async fn stale_stop_generation_mismatch_is_cancelled() {
    let db = database().await;
    let started_at = instant("2026-07-15T16:30:00Z");
    db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, started_at)
        .await
        .expect("start automation");
    db.try_acquire_task_board_automation_run(&acquire_request(
        "run-stale-stop-generation",
        TaskBoardAutomationRunTrigger::Scheduled,
        started_at,
    ))
    .await
    .expect("acquire run");
    query(
        "UPDATE task_board_orchestrator_control
         SET stop_generation = stop_generation + 1 WHERE singleton = 1",
    )
    .execute(db.pool())
    .await
    .expect("advance stop generation");

    db.recover_stale_task_board_automation_runs(started_at + Duration::seconds(30))
        .await
        .expect("recover mismatched run");

    assert_eq!(
        terminal_audit_outcome(&db, "run-stale-stop-generation").await,
        "cancelled"
    );
}

#[tokio::test]
async fn stale_recovery_rolls_back_when_audit_insert_fails() {
    let db = database().await;
    let started_at = instant("2026-07-15T17:00:00Z");
    db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, started_at)
        .await
        .expect("start automation");
    db.try_acquire_task_board_automation_run(&acquire_request(
        "run-stale-audit-failure",
        TaskBoardAutomationRunTrigger::Scheduled,
        started_at,
    ))
    .await
    .expect("acquire run");
    let revision = db
        .task_board_revision()
        .await
        .expect("revision before recovery");
    fail_automation_audit_inserts(&db).await;

    let error = db
        .recover_stale_task_board_automation_runs(started_at + Duration::seconds(30))
        .await
        .expect_err("audit failure must roll back stale recovery");

    assert!(
        error
            .to_string()
            .contains("simulated automation audit failure")
    );
    let row = query_as::<_, (String, Option<String>, i64)>(
        "SELECT state, outcome, revision
         FROM task_board_orchestrator_runs WHERE run_id = ?1",
    )
    .bind("run-stale-audit-failure")
    .fetch_one(db.pool())
    .await
    .expect("load run after failed recovery");
    assert_eq!(row, ("running".into(), None, 1));
    assert_eq!(
        automation_audit_count(&db, "run-stale-audit-failure").await,
        1
    );
    assert_eq!(
        db.task_board_revision()
            .await
            .expect("revision after failed recovery"),
        revision
    );
}

async fn active_run_count(db: &crate::daemon::db::AsyncDaemonDb) -> i64 {
    query_as::<_, (i64,)>(
        "SELECT COUNT(*) FROM task_board_orchestrator_runs
         WHERE state IN ('running', 'cancelling')",
    )
    .fetch_one(db.pool())
    .await
    .expect("count active automation runs")
    .0
}

async fn run_count(db: &crate::daemon::db::AsyncDaemonDb) -> i64 {
    query_as::<_, (i64,)>("SELECT COUNT(*) FROM task_board_orchestrator_runs")
        .fetch_one(db.pool())
        .await
        .expect("count automation runs")
        .0
}

async fn terminal_audit_outcome(db: &crate::daemon::db::AsyncDaemonDb, run_id: &str) -> String {
    query_as::<_, (String,)>(
        "SELECT outcome FROM audit_events
         WHERE correlation_id = ?1 AND kind != 'task_board.automation.run.started'
         ORDER BY recorded_at DESC, id DESC LIMIT 1",
    )
    .bind(run_id)
    .fetch_one(db.pool())
    .await
    .expect("load terminal automation audit")
    .0
}
