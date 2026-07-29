use chrono::{DateTime, Utc};
use sqlx::{query, query_scalar};

use super::TaskBoardRunAcquireRequest;
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{TaskBoardAutomationRunTrigger, TaskBoardAutomationScope};

pub(super) fn instant(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .expect("valid test instant")
        .with_timezone(&Utc)
}

pub(super) async fn database() -> AsyncDaemonDb {
    let temp = tempfile::tempdir().expect("temp dir");
    let path = temp.keep().join("harness.db");
    AsyncDaemonDb::connect(&path).await.expect("open database")
}

pub(super) async fn fail_automation_audit_inserts(db: &AsyncDaemonDb) {
    query(
        "CREATE TRIGGER fail_automation_audit
         BEFORE INSERT ON audit_events
         BEGIN SELECT RAISE(FAIL, 'simulated automation audit failure'); END",
    )
    .execute(db.pool())
    .await
    .expect("install automation audit failure trigger");
}

pub(super) async fn automation_audit_count(db: &AsyncDaemonDb, run_id: &str) -> i64 {
    query_scalar::<_, i64>("SELECT COUNT(*) FROM audit_events WHERE correlation_id = ?1")
        .bind(run_id)
        .fetch_one(db.pool())
        .await
        .expect("count automation audit events")
}

pub(super) fn acquire_request(
    run_id: &str,
    trigger: TaskBoardAutomationRunTrigger,
    now: DateTime<Utc>,
) -> TaskBoardRunAcquireRequest {
    TaskBoardRunAcquireRequest {
        run_id: run_id.to_string(),
        trigger,
        actor: Some("scheduler-test".into()),
        dry_run: false,
        scope: TaskBoardAutomationScope::default(),
        lease_owner: format!("owner-{run_id}"),
        now,
    }
}

pub(super) async fn seed_run(
    db: &AsyncDaemonDb,
    run_id: &str,
    state: &str,
    outcome: Option<&str>,
    completed_at: Option<DateTime<Utc>>,
) {
    let completed_at = completed_at.map(|value| value.to_rfc3339());
    let observed_at = completed_at
        .clone()
        .unwrap_or_else(|| "2026-07-15T00:00:00+00:00".into());
    query(
        "INSERT INTO task_board_orchestrator_runs (
            run_id, trigger, actor, dry_run, scope_json, state, outcome, lease_owner,
            lease_epoch, lease_expires_at, stop_generation, started_at, heartbeat_at,
            completed_at
         ) VALUES (?1, 'manual', 'scheduler-test', 0, '{}', ?2, ?3, ?4, 1,
                   '2026-07-16T00:00:00+00:00', 0, ?5, ?5, ?6)",
    )
    .bind(run_id)
    .bind(state)
    .bind(outcome)
    .bind(format!("owner-{run_id}"))
    .bind(observed_at)
    .bind(completed_at)
    .execute(db.pool())
    .await
    .expect("seed automation run");
}
