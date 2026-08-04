use harness_workspace::workspace::utc_now;

use super::{AgentTurnRunSnapshot, AgentTurnRunStatus};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db::prelude::*;
use crate::daemon::db_open::AsyncDaemonDbConnect;

async fn open_db() -> (tempfile::TempDir, AsyncDaemonDb) {
    let dir = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open async db");
    (dir, db)
}

fn snapshot(run_id: &str, status: AgentTurnRunStatus) -> AgentTurnRunSnapshot {
    let now = utc_now();
    AgentTurnRunSnapshot {
        run_id: run_id.into(),
        session_id: Some("session-a".into()),
        task_id: Some("task-a".into()),
        board_item_id: Some("item-a".into()),
        workflow_execution_id: Some("wf-a".into()),
        project_dir: Some("/tmp/project".into()),
        requested_runtime: "openrouter".into(),
        actual_runtime: Some("openrouter".into()),
        runtime_turn_id: Some(format!("turn-{run_id}")),
        requested_model: Some("auto".into()),
        actual_model: None,
        status,
        source_revision: Some("0123456789abcdef0123456789abcdef01234567".into()),
        report: None,
        stop_reason: None,
        error: None,
        created_at: now.clone(),
        updated_at: now,
    }
}

fn legacy_snapshot(run_id: &str, status: AgentTurnRunStatus) -> AgentTurnRunSnapshot {
    AgentTurnRunSnapshot {
        runtime_turn_id: None,
        ..snapshot(run_id, status)
    }
}

/// A committed concurrency admission row is inserted with foreign keys off:
/// the release path only updates the row's own state, so its decision/intent
/// parents are irrelevant here and seeding the whole graph would test nothing
/// extra. Foreign keys are restored on the same connection before it returns
/// to the pool, so no later query silently runs with enforcement disabled.
async fn insert_committed_admission(db: &AsyncDaemonDb, ledger_id: &str, managed_worker_id: &str) {
    let mut conn = db.pool().acquire().await.expect("acquire connection");
    sqlx::query("PRAGMA foreign_keys = OFF")
        .execute(&mut *conn)
        .await
        .expect("suspend foreign keys");
    let inserted = sqlx::query(
        "INSERT INTO task_board_dispatch_admission_ledger (
             ledger_id, decision_id, decision, intent_id, generation, item_id, canonical_key,
             kind, scope, amount, limit_value, state, managed_worker_id, reserved_at, committed_at
         ) VALUES (?1, 'dec-1', 'allowed', 'intent-1', 1, 'item-1', 'key-1',
             'concurrency', 'scope-1', 1, 1, 'committed', ?2,
             '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z')",
    )
    .bind(ledger_id)
    .bind(managed_worker_id)
    .execute(&mut *conn)
    .await;
    // Restore enforcement before asserting the insert, so a failed insert can
    // never hand a foreign-keys-off connection back to the pool.
    sqlx::query("PRAGMA foreign_keys = ON")
        .execute(&mut *conn)
        .await
        .expect("restore foreign keys");
    inserted.expect("insert committed admission");
}

async fn admission_state(db: &AsyncDaemonDb, ledger_id: &str) -> String {
    sqlx::query_scalar::<_, String>(
        "SELECT state FROM task_board_dispatch_admission_ledger WHERE ledger_id = ?1",
    )
    .bind(ledger_id)
    .fetch_one(db.pool())
    .await
    .expect("read admission state")
}

#[tokio::test]
async fn start_by_id_is_idempotent_and_records_requested_and_actual() {
    let (_dir, db) = open_db().await;
    let first = db
        .record_agent_turn_run_started(&snapshot("run-1", AgentTurnRunStatus::Running))
        .await
        .expect("record start");
    assert_eq!(first.requested_runtime, "openrouter");
    assert_eq!(first.actual_runtime.as_deref(), Some("openrouter"));
    assert_eq!(first.requested_model.as_deref(), Some("auto"));

    // A repeat start with a different model must not clobber the live run.
    let mut retry = snapshot("run-1", AgentTurnRunStatus::Running);
    retry.requested_model = Some("changed".into());
    let second = db
        .record_agent_turn_run_started(&retry)
        .await
        .expect("record start again");
    assert_eq!(second.requested_model.as_deref(), Some("auto"));
    assert_eq!(second.status, AgentTurnRunStatus::Running);
}

#[tokio::test]
async fn terminal_outcome_is_sticky_and_records_actual_model() {
    let (_dir, db) = open_db().await;
    db.record_agent_turn_run_started(&snapshot("run-2", AgentTurnRunStatus::Running))
        .await
        .expect("record start");

    let mut completed = snapshot("run-2", AgentTurnRunStatus::Completed);
    completed.actual_model = Some("deepseek/deepseek-v4-flash".into());
    completed.report = Some(r#"{"summary":"Reviewed."}"#.into());
    completed.stop_reason = Some("end_turn".into());
    db.save_agent_turn_run(&completed)
        .await
        .expect("save completed");

    // A late poll that only knows a running status must not revert the outcome
    // or erase the enrichment.
    db.save_agent_turn_run(&snapshot("run-2", AgentTurnRunStatus::Running))
        .await
        .expect("save late running");

    let stored = db
        .agent_turn_run("run-2")
        .await
        .expect("load")
        .expect("run exists");
    assert_eq!(stored.status, AgentTurnRunStatus::Completed);
    assert_eq!(stored.requested_model.as_deref(), Some("auto"));
    assert_eq!(
        stored.actual_model.as_deref(),
        Some("deepseek/deepseek-v4-flash")
    );
    assert_eq!(stored.report.as_deref(), Some(r#"{"summary":"Reviewed."}"#));
}

#[tokio::test]
async fn terminal_row_is_frozen_against_later_writes() {
    let (_dir, db) = open_db().await;
    db.record_agent_turn_run_started(&snapshot("run-6", AgentTurnRunStatus::Running))
        .await
        .expect("record start");

    let mut completed = snapshot("run-6", AgentTurnRunStatus::Completed);
    completed.actual_model = Some("deepseek/deepseek-v4-flash".into());
    db.save_agent_turn_run(&completed)
        .await
        .expect("save completed");

    // A later write that would flip the run to failed with an error must not
    // touch the already-terminal row: exactly one terminal outcome stands.
    let mut failed = snapshot("run-6", AgentTurnRunStatus::Failed);
    failed.error = Some("late failure".into());
    db.save_agent_turn_run(&failed).await.expect("save failed");

    let stored = db
        .agent_turn_run("run-6")
        .await
        .expect("load")
        .expect("run exists");
    assert_eq!(stored.status, AgentTurnRunStatus::Completed);
    assert!(stored.error.is_none());
    assert_eq!(
        stored.actual_model.as_deref(),
        Some("deepseek/deepseek-v4-flash")
    );
}

#[tokio::test]
async fn restart_settles_uncorrelated_legacy_run_exactly_once() {
    let (_dir, db) = open_db().await;
    db.record_agent_turn_run_started(&legacy_snapshot("run-3", AgentTurnRunStatus::Running))
        .await
        .expect("record legacy start");

    let settled = db
        .reconcile_interrupted_agent_turn_runs()
        .await
        .expect("first reconcile");
    assert_eq!(settled, 1);
    let after = db
        .agent_turn_run("run-3")
        .await
        .expect("load")
        .expect("run exists");
    assert_eq!(after.status, AgentTurnRunStatus::Failed);
    assert!(after.error.is_some());

    let again = db
        .reconcile_interrupted_agent_turn_runs()
        .await
        .expect("second reconcile");
    assert_eq!(again, 0);
    let unchanged = db
        .agent_turn_run("run-3")
        .await
        .expect("load")
        .expect("run exists");
    assert_eq!(unchanged.status, AgentTurnRunStatus::Failed);
}

#[tokio::test]
async fn restart_preserves_correlated_active_run_for_harvesting() {
    let (_dir, db) = open_db().await;
    db.record_agent_turn_run_started(&snapshot("run-correlated", AgentTurnRunStatus::Running))
        .await
        .expect("record correlated start");

    let settled = db
        .reconcile_interrupted_agent_turn_runs()
        .await
        .expect("reconcile");

    assert_eq!(settled, 0);
    assert_eq!(
        db.agent_turn_run("run-correlated")
            .await
            .expect("load")
            .expect("run exists")
            .status,
        AgentTurnRunStatus::Running
    );
}

#[tokio::test]
async fn terminal_save_releases_managed_worker_admission() {
    let (_dir, db) = open_db().await;
    insert_committed_admission(&db, "led-1", "run-4").await;
    db.record_agent_turn_run_started(&snapshot("run-4", AgentTurnRunStatus::Running))
        .await
        .expect("record start");
    assert_eq!(admission_state(&db, "led-1").await, "committed");

    let mut failed = snapshot("run-4", AgentTurnRunStatus::Failed);
    failed.error = Some("boom".into());
    db.save_agent_turn_run(&failed).await.expect("save failed");

    assert_eq!(admission_state(&db, "led-1").await, "released");
}

#[tokio::test]
async fn restart_reconcile_releases_managed_worker_admission() {
    let (_dir, db) = open_db().await;
    insert_committed_admission(&db, "led-2", "run-5").await;
    db.record_agent_turn_run_started(&legacy_snapshot("run-5", AgentTurnRunStatus::Running))
        .await
        .expect("record legacy start");

    let settled = db
        .reconcile_interrupted_agent_turn_runs()
        .await
        .expect("reconcile");
    assert_eq!(settled, 1);
    assert_eq!(admission_state(&db, "led-2").await, "released");
}
