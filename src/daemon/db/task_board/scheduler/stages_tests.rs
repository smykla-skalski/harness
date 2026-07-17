use std::sync::Arc;

use serde::Deserialize;
use sqlx::{query, query_as};
use tokio::sync::Barrier;

use super::test_support::{
    acquire_request, automation_audit_count, database, fail_automation_audit_inserts, instant,
};
use crate::daemon::db::{TaskBoardAutomationRunAdmission, TaskBoardAutomationRunLease};
use crate::task_board::{
    TaskBoardAutomationRunOutcome, TaskBoardAutomationRunStage, TaskBoardAutomationRunTrigger,
};

#[derive(Deserialize)]
struct StoredStageSummary {
    #[serde(default)]
    stages: Vec<TaskBoardAutomationRunStage>,
}

#[tokio::test]
async fn concurrent_stage_upserts_are_canonical_and_revisioned() {
    let db = database().await;
    let lease = acquire_run(&db, "run-stages", instant("2026-07-15T12:00:00Z")).await;
    let gate = Arc::new(Barrier::new(2));
    let first_db = db.clone();
    let first_gate = Arc::clone(&gate);
    let first_lease = lease.clone();
    let second_db = db.clone();
    let second_gate = Arc::clone(&gate);
    let second_lease = lease.clone();

    let (first, second) = tokio::join!(
        async move {
            first_gate.wait().await;
            first_db
                .upsert_task_board_automation_run_stage(
                    &first_lease,
                    &stage(2, "evaluate", "completed"),
                    instant("2026-07-15T12:00:00Z"),
                )
                .await
        },
        async move {
            second_gate.wait().await;
            second_db
                .upsert_task_board_automation_run_stage(
                    &second_lease,
                    &stage(1, "synchronize", "completed"),
                    instant("2026-07-15T12:00:00Z"),
                )
                .await
        }
    );
    first.expect("upsert first stage");
    second.expect("upsert second stage");

    let (stages, revision) = load_stages(&db, "run-stages").await;
    assert_eq!(stage_sequences(&stages), [1, 2]);
    assert_eq!(revision, 3);

    let mut replacement = stage(1, "synchronize", "failed");
    replacement.summary = Some("replaced".into());
    assert_eq!(
        db.upsert_task_board_automation_run_stage(
            &lease,
            &replacement,
            instant("2026-07-15T12:00:00Z"),
        )
        .await
        .expect("replace stage"),
        4
    );
    let (stages, revision) = load_stages(&db, "run-stages").await;
    assert_eq!(stage_sequences(&stages), [1, 2]);
    assert_eq!(stages[0].state, "failed");
    assert_eq!(stages[0].summary.as_deref(), Some("replaced"));
    assert_eq!(revision, 4);
}

#[tokio::test]
async fn malformed_persisted_stage_summary_fails_closed() {
    let db = database().await;
    let lease = acquire_run(&db, "run-malformed", instant("2026-07-15T13:00:00Z")).await;
    query(
        "UPDATE task_board_orchestrator_runs SET stage_summary_json = '{\"stages\":42}'
         WHERE run_id = 'run-malformed'",
    )
    .execute(db.pool())
    .await
    .expect("seed malformed stages");

    let error = db
        .upsert_task_board_automation_run_stage(
            &lease,
            &stage(1, "synchronize", "completed"),
            instant("2026-07-15T13:00:00Z"),
        )
        .await
        .expect_err("reject malformed stage summary");
    assert!(
        error
            .to_string()
            .contains("parse task board automation run stages")
    );
    let revision = query_as::<_, (i64,)>(
        "SELECT revision FROM task_board_orchestrator_runs WHERE run_id = 'run-malformed'",
    )
    .fetch_one(db.pool())
    .await
    .expect("load unchanged revision")
    .0;
    assert_eq!(revision, 1);
}

#[tokio::test]
async fn invalid_stage_input_is_rejected_before_storage() {
    let db = database().await;
    let lease = acquire_run(&db, "run-invalid", instant("2026-07-15T14:00:00Z")).await;

    let mut invalid = stage(1, "", "running");
    assert!(
        db.upsert_task_board_automation_run_stage(
            &lease,
            &invalid,
            instant("2026-07-15T14:00:00Z"),
        )
        .await
        .is_err()
    );
    invalid.stage = "synchronize".into();
    invalid.recorded_at = "not-an-instant".into();
    assert!(
        db.upsert_task_board_automation_run_stage(
            &lease,
            &invalid,
            instant("2026-07-15T14:00:00Z"),
        )
        .await
        .is_err()
    );

    let (stages, revision) = load_stages(&db, "run-invalid").await;
    assert!(stages.is_empty());
    assert_eq!(revision, 1);
}

#[tokio::test]
async fn terminal_run_rejects_stage_writes_from_its_old_lease() {
    let db = database().await;
    let now = instant("2026-07-15T15:00:00Z");
    let lease = acquire_run(&db, "run-terminal-stage", now).await;
    db.finalize_task_board_automation_run(
        &lease,
        TaskBoardAutomationRunOutcome::Completed,
        None,
        None,
        now,
    )
    .await
    .expect("finalize run");

    let error = db
        .upsert_task_board_automation_run_stage(&lease, &stage(1, "synchronize", "completed"), now)
        .await
        .expect_err("terminal run must reject stage write");
    assert!(error.to_string().contains("lost its stage-write lease"));
    let (stages, revision) = load_stages(&db, "run-terminal-stage").await;
    assert!(stages.is_empty());
    assert_eq!(revision, 2);
}

#[tokio::test]
async fn expired_run_rejects_stage_writes_before_recovery() {
    let db = database().await;
    let now = instant("2026-07-15T15:30:00Z");
    let lease = acquire_run(&db, "run-expired-stage", now).await;

    let error = db
        .upsert_task_board_automation_run_stage(
            &lease,
            &stage(1, "synchronize", "completed"),
            now + chrono::Duration::seconds(31),
        )
        .await
        .expect_err("expired run must reject stage write");

    assert!(error.to_string().contains("lost its stage-write lease"));
    let (stages, revision) = load_stages(&db, "run-expired-stage").await;
    assert!(stages.is_empty());
    assert_eq!(revision, 1);
    assert_eq!(automation_audit_count(&db, &lease.run_id).await, 1);
}

#[tokio::test]
async fn stage_write_rolls_back_when_audit_insert_fails() {
    let db = database().await;
    let now = instant("2026-07-15T16:00:00Z");
    let lease = acquire_run(&db, "run-stage-audit-failure", now).await;
    fail_automation_audit_inserts(&db).await;

    let error = db
        .upsert_task_board_automation_run_stage(&lease, &stage(1, "synchronize", "completed"), now)
        .await
        .expect_err("audit failure must roll back stage write");

    assert!(
        error
            .to_string()
            .contains("simulated automation audit failure")
    );
    let (stages, revision) = load_stages(&db, &lease.run_id).await;
    assert!(stages.is_empty());
    assert_eq!(revision, 1);
    assert_eq!(automation_audit_count(&db, &lease.run_id).await, 1);
}

fn stage(sequence: u64, name: &str, state: &str) -> TaskBoardAutomationRunStage {
    TaskBoardAutomationRunStage {
        sequence,
        stage: name.into(),
        state: state.into(),
        recorded_at: "2026-07-15T12:00:00Z".into(),
        summary: None,
        payload: None,
    }
}

async fn load_stages(
    db: &crate::daemon::db::AsyncDaemonDb,
    run_id: &str,
) -> (Vec<TaskBoardAutomationRunStage>, i64) {
    let (stored, revision) = query_as::<_, (String, i64)>(
        "SELECT stage_summary_json, revision FROM task_board_orchestrator_runs WHERE run_id = ?1",
    )
    .bind(run_id)
    .fetch_one(db.pool())
    .await
    .expect("load stage summary");
    let summary =
        serde_json::from_str::<StoredStageSummary>(&stored).expect("decode stage summary");
    (summary.stages, revision)
}

fn stage_sequences(stages: &[TaskBoardAutomationRunStage]) -> Vec<u64> {
    stages.iter().map(|stage| stage.sequence).collect()
}

async fn acquire_run(
    db: &crate::daemon::db::AsyncDaemonDb,
    run_id: &str,
    now: chrono::DateTime<chrono::Utc>,
) -> TaskBoardAutomationRunLease {
    match db
        .try_acquire_task_board_automation_run(&acquire_request(
            run_id,
            TaskBoardAutomationRunTrigger::Manual,
            now,
        ))
        .await
        .expect("acquire run")
    {
        TaskBoardAutomationRunAdmission::Acquired(lease) => lease,
        admission => panic!("expected acquired run, got {admission:?}"),
    }
}
