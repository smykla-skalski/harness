use std::path::Path;

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{SqlitePool, query};

use super::{ScanRow, complete_scan_item_in_tx, next_scan_item_in_tx};

const UPDATED_AT: &str = "2026-07-20T10:00:00Z";
const CHURNED_AT: &str = "2026-07-20T10:01:00Z";

#[tokio::test]
async fn finite_cycle_survives_restart_and_reaches_a_terminal_last_page() {
    let temp = tempfile::tempdir().expect("create controller scan temp directory");
    let database_path = temp.path().join("controller-scan.db");
    let pool = open_pool(&database_path).await;
    seed_assignments(&pool, 130).await;

    let (first, first_incomplete) = drain_items(&pool, 64).await;
    assert!(first_incomplete);
    assert_eq!(first.len(), 64);
    drop(pool);

    let restarted = open_pool(&database_path).await;
    let (second, second_incomplete) = drain_items(&restarted, 64).await;
    assert!(second_incomplete);
    assert_eq!(second.len(), 64);
    let (last, last_incomplete) = drain_items(&restarted, 64).await;
    assert!(!last_incomplete);
    assert_eq!(last, ["assignment-cycle-128", "assignment-cycle-129"]);

    let mut visited = first;
    visited.extend(second);
    visited.extend(last);
    visited.sort();
    visited.dedup();
    assert_eq!(visited.len(), 130);
}

#[tokio::test]
async fn high_water_boundary_completes_despite_newer_churn() {
    let temp = tempfile::tempdir().expect("create controller scan temp directory");
    let pool = open_pool(&temp.path().join("controller-scan.db")).await;
    seed_assignments(&pool, 65).await;

    let (first, first_incomplete) = drain_items(&pool, 64).await;
    assert!(first_incomplete);
    assert_eq!(first.len(), 64);
    query(
        "UPDATE task_board_remote_assignments SET updated_at = ?2
         WHERE assignment_id = ?1",
    )
    .bind("assignment-cycle-064")
    .bind(CHURNED_AT)
    .execute(&pool)
    .await
    .expect("move a processed row beyond the cycle boundary");
    insert_assignment(&pool, "assignment-cycle-new", "running", CHURNED_AT).await;

    let (last, last_incomplete) = drain_items(&pool, 64).await;
    assert!(!last_incomplete);
    assert_eq!(last, ["assignment-cycle-064"]);

    let (next_first, next_incomplete) = drain_items(&pool, 64).await;
    assert!(next_incomplete);
    assert_eq!(next_first.len(), 64);
    let (next_last, next_last_incomplete) = drain_items(&pool, 64).await;
    assert!(!next_last_incomplete);
    assert!(next_last.iter().any(|id| id == "assignment-cycle-new"));
}

#[tokio::test]
async fn selected_generation_replays_after_crash_until_acknowledged() {
    let temp = tempfile::tempdir().expect("create controller scan temp directory");
    let database_path = temp.path().join("controller-scan.db");
    let pool = open_pool(&database_path).await;
    seed_assignments(&pool, 2).await;

    let selected = next_item(&pool).await.expect("select controller item");
    drop(pool);
    let restarted = open_pool(&database_path).await;
    let replayed = next_item(&restarted)
        .await
        .expect("replay unacknowledged controller item");
    assert_eq!(replayed, selected);
    assert!(ack_item(&restarted, &replayed).await);
    let second = next_item(&restarted)
        .await
        .expect("select second controller item");
    assert_ne!(second.assignment_id, selected.assignment_id);
    assert!(!ack_item(&restarted, &second).await);
}

async fn open_pool(path: &Path) -> SqlitePool {
    let options = SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(true);
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .expect("open controller scan database");
    query(
        "CREATE TABLE IF NOT EXISTS task_board_execution_hosts (
             host_id TEXT PRIMARY KEY,
             host_role TEXT NOT NULL
         )",
    )
    .execute(&pool)
    .await
    .expect("create controller host schema");
    query(
        "CREATE TABLE IF NOT EXISTS task_board_remote_assignments (
             assignment_id TEXT PRIMARY KEY,
             host_id TEXT NOT NULL,
             legacy_migrated INTEGER NOT NULL,
             fencing_epoch INTEGER NOT NULL DEFAULT 1,
             state TEXT NOT NULL,
             request_sha256 TEXT,
             lease_id TEXT,
             cleanup_completed_at TEXT,
             controller_handoff_kind TEXT,
             offered_at TEXT NOT NULL,
             updated_at TEXT NOT NULL
         )",
    )
    .execute(&pool)
    .await
    .expect("create controller assignment schema");
    query(
        "CREATE TABLE IF NOT EXISTS task_board_remote_recovery_quarantine (
             assignment_id TEXT PRIMARY KEY,
             fencing_epoch INTEGER NOT NULL,
             assignment_state TEXT NOT NULL,
             assignment_updated_at TEXT NOT NULL,
             next_attempt_at TEXT NOT NULL
         )",
    )
    .execute(&pool)
    .await
    .expect("create controller quarantine schema");
    query(
        "CREATE TABLE IF NOT EXISTS task_board_reconciliation_cursors (
             queue TEXT PRIMARY KEY,
             sort_updated_at TEXT NOT NULL,
             sort_execution_id TEXT NOT NULL
         ) WITHOUT ROWID",
    )
    .execute(&pool)
    .await
    .expect("create controller cursor schema");
    query(
        "INSERT OR IGNORE INTO task_board_execution_hosts (host_id, host_role)
         VALUES ('controller-host', 'controller_remote')",
    )
    .execute(&pool)
    .await
    .expect("seed controller host");
    pool
}

async fn seed_assignments(pool: &SqlitePool, count: usize) {
    for index in 0..count {
        let assignment_id = format!("assignment-cycle-{index:03}");
        let state = if index + 1 == count {
            "completed"
        } else {
            "running"
        };
        insert_assignment(pool, &assignment_id, state, UPDATED_AT).await;
    }
}

async fn insert_assignment(
    pool: &SqlitePool,
    assignment_id: &str,
    state: &str,
    order_at: &str,
) {
    query(
        "INSERT INTO task_board_remote_assignments (
             assignment_id, host_id, legacy_migrated, state, lease_id,
             cleanup_completed_at, offered_at, updated_at
         ) VALUES (?1, 'controller-host', 0, ?2, 'lease', NULL, ?3, ?3)",
    )
    .bind(assignment_id)
    .bind(state)
    .bind(order_at)
    .execute(pool)
    .await
    .expect("seed controller assignment");
}

async fn drain_items(pool: &SqlitePool, limit: usize) -> (Vec<String>, bool) {
    let mut ids = Vec::new();
    let mut incomplete = false;
    for _ in 0..limit {
        let Some(item) = next_item(pool).await else {
            return (ids, false);
        };
        ids.push(item.assignment_id.clone());
        incomplete = ack_item(pool, &item).await;
        if !incomplete {
            break;
        }
    }
    (ids, incomplete)
}

async fn next_item(pool: &SqlitePool) -> Option<ScanRow> {
    let mut transaction = pool.begin().await.expect("begin controller scan item");
    let item = next_scan_item_in_tx(&mut transaction, UPDATED_AT)
        .await
        .expect("scan controller item");
    transaction
        .commit()
        .await
        .expect("commit controller scan item");
    item
}

async fn ack_item(pool: &SqlitePool, item: &ScanRow) -> bool {
    let mut transaction = pool.begin().await.expect("begin controller scan ack");
    let incomplete = complete_scan_item_in_tx(&mut transaction, item, UPDATED_AT)
        .await
        .expect("acknowledge controller scan item");
    transaction
        .commit()
        .await
        .expect("commit controller scan ack");
    incomplete
}
