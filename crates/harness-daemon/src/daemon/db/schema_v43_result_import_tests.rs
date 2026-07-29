use super::tests::{
    insert_strict_assignment, legacy_v40_fixture, legacy_v40_fixture_at, strict_request,
};
use super::*;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use rusqlite::params;

const DIGEST_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const DIGEST_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const BASE: &str = "1111111111111111111111111111111111111111";
const RESULT: &str = "2222222222222222222222222222222222222222";

#[test]
fn fresh_schema_owns_strict_result_import_journal() {
    let db = DaemonDb::open_in_memory().expect("open daemon db");
    let columns: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_remote_result_imports')
             WHERE name IN (
               'assignment_id', 'fencing_epoch', 'execution_id', 'action_key', 'attempt',
               'idempotency_key', 'offer_request_sha256', 'status_sha256', 'result_sha256',
               'result_artifact_sha256', 'bundle_sha256', 'parent_record_sha256',
               'worktree_path', 'git_dir', 'common_git_dir', 'branch_ref',
               'base_revision', 'result_revision',
               'advertised_ref', 'import_ref', 'object_format', 'import_sha256', 'state',
               'prepared_at', 'applied_at', 'adopted_at', 'last_error'
             )",
            [],
            |row| row.get(0),
        )
        .expect("inspect result import columns");
    assert_eq!(columns, 27);

    let index: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index'
             AND name = 'task_board_remote_result_imports_recovery'",
            [],
            |row| row.get(0),
        )
        .expect("inspect result import recovery index");
    assert_eq!(index, 1);
}

#[test]
fn synchronous_upgrade_installs_the_same_result_import_shape() {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("upgrade synchronous daemon database");
    let columns: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_remote_result_imports')",
            [],
            |row| row.get(0),
        )
        .expect("inspect synchronous result import columns");
    assert_eq!(columns, 27);
    let common_git_dir: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_remote_result_imports')
             WHERE name = 'common_git_dir' AND \"notnull\" = 1 AND type = 'TEXT'",
            [],
            |row| row.get(0),
        )
        .expect("inspect synchronous common git directory column");
    assert_eq!(common_git_dir, 1);
}

#[tokio::test]
async fn async_upgrade_installs_the_same_result_import_shape() {
    let directory = tempfile::tempdir().expect("schema fixture directory");
    let path = directory.path().join("daemon.sqlite3");
    let legacy = legacy_v40_fixture_at(&path);
    drop(legacy);

    let db = AsyncDaemonDb::connect(&path)
        .await
        .expect("upgrade async daemon database");
    let columns = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM pragma_table_info('task_board_remote_result_imports')",
    )
    .fetch_one(db.pool())
    .await
    .expect("inspect async result import columns");
    assert_eq!(columns, 27);
    let common_git_dir = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM pragma_table_info('task_board_remote_result_imports')
         WHERE name = 'common_git_dir' AND \"notnull\" = 1 AND type = 'TEXT'",
    )
    .fetch_one(db.pool())
    .await
    .expect("inspect async common git directory column");
    assert_eq!(common_git_dir, 1);
    let index = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index'
         AND name = 'task_board_remote_result_imports_recovery'",
    )
    .fetch_one(db.pool())
    .await
    .expect("inspect async result import index");
    assert_eq!(index, 1);
}

#[test]
fn repair_restores_result_import_index_but_refuses_table_drift() {
    let db = DaemonDb::open_in_memory().expect("open daemon db");
    db.connection()
        .execute_batch("DROP INDEX task_board_remote_result_imports_recovery;")
        .expect("drop repairable result import index");

    run(db.connection()).expect("repair result import index");
    let repaired: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index'
             AND name = 'task_board_remote_result_imports_recovery'",
            [],
            |row| row.get(0),
        )
        .expect("inspect repaired result import index");
    assert_eq!(repaired, 1);

    db.connection()
        .execute(
            "ALTER TABLE task_board_remote_result_imports ADD COLUMN mutable_retry_hint TEXT",
            [],
        )
        .expect("malform result import journal");
    let error = run(db.connection()).expect_err("result import table drift must fail closed");
    assert!(error.to_string().contains("refusing destructive repair"));
}

#[test]
fn result_import_journal_binds_assignment_generation_and_state_shape() {
    let db = strict_assignment_fixture();
    let generation_error = insert_result_import(&db, 2, "prepared", None, None, None)
        .expect_err("result import journal must bind the exact assignment generation");
    assert!(generation_error.to_string().contains("FOREIGN KEY"));

    let digest_error = db
        .connection()
        .execute(
            &insert_sql("prepared"),
            params![
                1_i64,
                "A".repeat(64),
                Option::<String>::None,
                Option::<String>::None,
                Option::<String>::None,
            ],
        )
        .expect_err("uppercase import digest must fail closed");
    assert!(digest_error.to_string().contains("CHECK constraint failed"));

    let state_error =
        insert_result_import(&db, 1, "adopted", None, Some("2026-07-20T09:01:00Z"), None)
            .expect_err("adopted state requires both monotonic timestamps");
    assert!(state_error.to_string().contains("CHECK constraint failed"));

    insert_result_import(
        &db,
        1,
        "manual_required",
        Some("unsafe worktree state"),
        None,
        None,
    )
    .expect("persist strict manual-required evidence");
}

fn strict_assignment_fixture() -> DaemonDb {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution ledger");
    let request = strict_request("assignment-a", "execution-a", 1, DIGEST_A);
    insert_strict_assignment(db.connection(), "assignment-a", 1, &request)
        .expect("insert strict assignment");
    db
}

fn insert_result_import(
    db: &DaemonDb,
    epoch: i64,
    state: &str,
    error: Option<&str>,
    applied_at: Option<&str>,
    adopted_at: Option<&str>,
) -> rusqlite::Result<usize> {
    db.connection().execute(
        &insert_sql(state),
        params![epoch, DIGEST_B, applied_at, adopted_at, error],
    )
}

fn insert_sql(state: &str) -> String {
    format!(
        "INSERT INTO task_board_remote_result_imports (
           assignment_id, fencing_epoch, execution_id, action_key, attempt, idempotency_key,
           offer_request_sha256, status_sha256, result_sha256, result_artifact_sha256,
           bundle_sha256, parent_record_sha256, worktree_path, git_dir, common_git_dir, branch_ref,
           base_revision, result_revision, advertised_ref, import_ref, object_format,
           import_sha256, state, prepared_at, applied_at, adopted_at, last_error
         ) VALUES (
           'assignment-a', ?1, 'execution-a', 'implementation:1', 1,
           'idempotency-assignment-a', '{DIGEST_A}', '{DIGEST_A}', '{DIGEST_A}',
           '{DIGEST_A}', '{DIGEST_A}', '{DIGEST_A}', '/tmp/result-import',
           '/tmp/result-import/.git', '/tmp/result-import/.git',
           'refs/heads/task-board-result', '{BASE}', '{RESULT}',
           'refs/harness/task-board/results/assignment-a',
           'refs/harness/task-board/imports/assignment-a', 'sha1', ?2, '{state}',
           '2026-07-20T09:00:00Z', ?3, ?4, ?5
         )"
    )
}
