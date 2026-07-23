use sqlx::query_scalar;
use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{TaskBoardItem, TaskBoardStatus};

#[path = "triage_override_clear_audit_tests.rs"]
mod clear_audit;
#[path = "triage_override_contract_tests.rs"]
mod contract;
#[path = "triage_override_reservation_tests.rs"]
mod reservation;
#[path = "triage_override_rollback_tests.rs"]
mod rollback;
#[path = "triage_override_semantics_tests.rs"]
mod semantics;
#[path = "triage_override_survival_tests.rs"]
mod survival;

async fn connect() -> (tempfile::TempDir, AsyncDaemonDb) {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("connect db");
    (directory, db)
}

fn backlog_item(id: &str) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Title".into(),
        String::new(),
        "2026-07-23T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Backlog;
    item
}

async fn seq(db: &AsyncDaemonDb) -> i64 {
    db.task_board_items_snapshot(None)
        .await
        .expect("snapshot")
        .items_change_seq
}

async fn revision(db: &AsyncDaemonDb, item_id: &str) -> i64 {
    query_scalar("SELECT revision FROM task_board_items WHERE item_id = ?1")
        .bind(item_id)
        .fetch_one(db.pool())
        .await
        .expect("read revision")
}

async fn audit_count(db: &AsyncDaemonDb) -> i64 {
    query_scalar("SELECT COUNT(*) FROM audit_events")
        .fetch_one(db.pool())
        .await
        .expect("count audit events")
}

async fn audit_payload(db: &AsyncDaemonDb, kind: &str, item_id: &str) -> serde_json::Value {
    let raw: String = query_scalar(
        "SELECT payload_json FROM audit_events WHERE kind = ?1 AND subject = ?2
         ORDER BY recorded_at DESC LIMIT 1",
    )
    .bind(kind)
    .bind(item_id)
    .fetch_one(db.pool())
    .await
    .expect("read audit payload");
    serde_json::from_str(&raw).expect("parse audit payload")
}

async fn audit_actor(db: &AsyncDaemonDb, kind: &str, item_id: &str) -> Option<String> {
    query_scalar(
        "SELECT actor FROM audit_events WHERE kind = ?1 AND subject = ?2
         ORDER BY recorded_at DESC LIMIT 1",
    )
    .bind(kind)
    .bind(item_id)
    .fetch_one(db.pool())
    .await
    .expect("read audit actor")
}

/// Seed a genuinely decided `BuiltInV1` Todo verdict (a real decision row,
/// real placement) so later reads see a congruent starting point.
async fn seed_decided_todo(db: &AsyncDaemonDb, item_id: &str) {
    use super::super::items::{load_item_in_tx, replace_item_in_tx};
    use super::super::triage_apply::apply_builtin_v1_triage_in_tx;

    db.create_task_board_item(backlog_item(item_id))
        .await
        .expect("seed item");
    let mut transaction = db
        .begin_immediate_transaction("seed decided todo")
        .await
        .expect("begin transaction");
    let (mut item, revision) = load_item_in_tx(&mut transaction, item_id)
        .await
        .expect("load item")
        .expect("item exists");
    item.tags = vec!["kind/bug".into()];
    apply_builtin_v1_triage_in_tx(
        &mut transaction,
        &mut item,
        "2026-07-23T00:00:00Z",
        false,
        None,
    )
    .await
    .expect("apply triage")
    .expect("decision recorded");
    replace_item_in_tx(&mut transaction, &item, revision + 1)
        .await
        .expect("persist triaged placement");
    transaction.commit().await.expect("commit");
}
