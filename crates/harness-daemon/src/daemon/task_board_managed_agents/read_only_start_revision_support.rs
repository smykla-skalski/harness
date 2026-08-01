//! Shared durable-state helpers for managed read-only start tests

use crate::daemon::db::AsyncDaemonDb;

pub(super) async fn bump_settings_revision(db: &AsyncDaemonDb) {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load current settings");
    settings.dry_run_default = !settings.dry_run_default;
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("bump settings revision");
}

pub(super) async fn engage_spawn_kill_switch(db: &AsyncDaemonDb) {
    db.update_policy_workspace(|workspace| {
        workspace.spawn_kill_switch = true;
        Ok(())
    })
    .await
    .expect("engage spawn kill switch");
}

pub(super) async fn codex_run_count(db: &AsyncDaemonDb) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM codex_runs")
        .fetch_one(db.pool())
        .await
        .expect("count Codex runs")
}

pub(super) async fn workflow_execution_count(db: &AsyncDaemonDb) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM task_board_workflow_executions")
        .fetch_one(db.pool())
        .await
        .expect("count workflow executions")
}

pub(in crate::daemon::task_board_managed_agents) async fn intent_status(
    db: &AsyncDaemonDb,
    intent_id: &str,
) -> String {
    sqlx::query_scalar("SELECT status FROM task_board_dispatch_intents WHERE intent_id = ?1")
        .bind(intent_id)
        .fetch_one(db.pool())
        .await
        .expect("load intent status")
}

pub(super) async fn intent_compensation_pending(db: &AsyncDaemonDb, intent_id: &str) -> bool {
    sqlx::query_scalar(
        "SELECT compensation_pending FROM task_board_dispatch_intents WHERE intent_id = ?1",
    )
    .bind(intent_id)
    .fetch_one(db.pool())
    .await
    .expect("load intent compensation state")
}

pub(in crate::daemon::task_board_managed_agents) async fn admission_state_counts(
    db: &AsyncDaemonDb,
    intent_id: &str,
) -> (i64, i64) {
    sqlx::query_as(
        "SELECT
             COALESCE(SUM(CASE WHEN state = 'reserved' THEN 1 ELSE 0 END), 0),
             COALESCE(SUM(CASE WHEN state = 'committed' THEN 1 ELSE 0 END), 0)
         FROM task_board_dispatch_admission_ledger WHERE intent_id = ?1",
    )
    .bind(intent_id)
    .fetch_one(db.pool())
    .await
    .expect("load dispatch admission states")
}

pub(super) async fn current_intent_claim(db: &AsyncDaemonDb, intent_id: &str) -> Option<String> {
    sqlx::query_scalar("SELECT claim_token FROM task_board_dispatch_intents WHERE intent_id = ?1")
        .bind(intent_id)
        .fetch_one(db.pool())
        .await
        .expect("load current intent claim")
}
