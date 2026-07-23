use sqlx::query_scalar;
use tempfile::tempdir;

use super::super::schema_repairs_triage_override::shape_needs_repair;
use super::run;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};

const DROP_V47_SQL: &str = "
ALTER TABLE task_board_items DROP COLUMN triage_override_set_at;
ALTER TABLE task_board_items DROP COLUMN triage_override_reason;
ALTER TABLE task_board_items DROP COLUMN triage_override_actor;
ALTER TABLE task_board_items DROP COLUMN triage_override_verdict;
UPDATE schema_meta SET value = '46' WHERE key = 'version';";

fn triage_override_column_count(db: &DaemonDb) -> i64 {
    db.connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_items')
             WHERE name IN (
                 'triage_override_verdict', 'triage_override_actor',
                 'triage_override_reason', 'triage_override_set_at'
             )",
            [],
            |row| row.get(0),
        )
        .expect("inspect triage override columns")
}

#[test]
fn fresh_schema_includes_v47_triage_override_columns() {
    let db = DaemonDb::open_in_memory().expect("open current database");

    assert_eq!(triage_override_column_count(&db), 4);
    assert_eq!(
        db.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
}

#[test]
fn v46_database_migrates_to_v47_and_restarts() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current database");
    db.connection()
        .execute_batch(DROP_V47_SQL)
        .expect("restore v46 schema");
    drop(db);

    let reopened = DaemonDb::open(&path).expect("migrate v46 database");
    assert_eq!(
        reopened.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    assert_eq!(triage_override_column_count(&reopened), 4);
    drop(reopened);

    let restarted = DaemonDb::open(&path).expect("restart migrated database");
    assert_eq!(
        restarted.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
}

#[tokio::test]
async fn async_upgrade_records_v46_then_v47_migrations() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current v46 database");
    db.connection()
        .execute_batch(DROP_V47_SQL)
        .expect("restore v46 schema");
    drop(db);

    let async_db = AsyncDaemonDb::connect(&path)
        .await
        .expect("upgrade v46 database asynchronously");

    assert_eq!(
        async_db.schema_version().await.expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    let migrations: Vec<i64> = query_scalar(
        "SELECT version FROM _sqlx_migrations WHERE version IN (40, 41) ORDER BY version",
    )
    .fetch_all(async_db.pool())
    .await
    .expect("read migration ledger");
    assert_eq!(migrations, vec![40, 41]);
}

#[test]
fn v47_repair_rebuilds_missing_triage_override_columns() {
    let db = DaemonDb::open_in_memory().expect("open current database");
    db.connection()
        .execute_batch(
            "ALTER TABLE task_board_items DROP COLUMN triage_override_set_at;
             ALTER TABLE task_board_items DROP COLUMN triage_override_reason;
             ALTER TABLE task_board_items DROP COLUMN triage_override_actor;
             ALTER TABLE task_board_items DROP COLUMN triage_override_verdict;",
        )
        .expect("drop triage override columns");

    assert!(shape_needs_repair(db.connection()).expect("inspect repair need"));
    run(db.connection()).expect("repair triage override columns");
    assert!(!shape_needs_repair(db.connection()).expect("inspect repaired shape"));
    assert_eq!(db.schema_version().expect("schema version"), "47");
    assert_eq!(triage_override_column_count(&db), 4);
}

#[test]
fn v47_refuses_destructive_repair_over_an_incompatible_override_verdict_column() {
    let db = DaemonDb::open_in_memory().expect("open current database");
    db.connection()
        .execute_batch(
            "ALTER TABLE task_board_items DROP COLUMN triage_override_set_at;
             ALTER TABLE task_board_items DROP COLUMN triage_override_reason;
             ALTER TABLE task_board_items DROP COLUMN triage_override_actor;
             ALTER TABLE task_board_items DROP COLUMN triage_override_verdict;
             ALTER TABLE task_board_items ADD COLUMN triage_override_verdict INTEGER NOT NULL DEFAULT 0;",
        )
        .expect("install an incompatible triage_override_verdict column");

    let repair_error = run(db.connection()).expect_err("refuse destructive repair");
    assert!(
        repair_error
            .to_string()
            .contains("refusing destructive repair"),
        "unexpected error: {repair_error}"
    );
}

#[test]
fn v47_override_columns_reject_incoherent_writes() {
    let db = DaemonDb::open_in_memory().expect("open current database");
    db.connection()
        .execute(
            "INSERT INTO task_board_items (
                 item_id, schema_version, title, body, status, priority, tags_json,
                 project_id, target_project_types_json, agent_mode, imported_from_provider,
                 planning_json, workflow_json, session_id, work_item_id, usage_json,
                 created_at, updated_at, deleted_at, revision, workflow_kind
             ) VALUES (
                 'item-1', 1, 'Title', '', 'backlog', 'medium', '[]',
                 NULL, '[]', 'headless', NULL, '{}', '{}', NULL, NULL, '{}',
                 '2026-07-22T00:00:00Z', '2026-07-22T00:00:00Z', NULL, 1,
                 'default_task'
             )",
            [],
        )
        .expect("seed one task board item");

    let missing_actor = db.connection().execute(
        "UPDATE task_board_items SET triage_override_verdict = 'todo', triage_override_set_at = '2026-07-22T00:00:00Z'
         WHERE item_id = 'item-1'",
        [],
    );
    assert!(
        missing_actor.is_err(),
        "an override verdict without an actor must be rejected by the CHECK constraint"
    );

    let reason_without_verdict = db.connection().execute(
        "UPDATE task_board_items SET triage_override_reason = 'looks fine' WHERE item_id = 'item-1'",
        [],
    );
    assert!(
        reason_without_verdict.is_err(),
        "an override reason without an active verdict must be rejected by the CHECK constraint"
    );

    let malformed_timestamp = db.connection().execute(
        "UPDATE task_board_items SET
             triage_override_verdict = 'todo',
             triage_override_actor = 'operator-1',
             triage_override_set_at = 'not-a-timestamp'
         WHERE item_id = 'item-1'",
        [],
    );
    assert!(
        malformed_timestamp.is_err(),
        "a non-canonical override set_at must be rejected by the CHECK constraint"
    );

    for (name, actor, reason) in [
        ("empty actor", String::new(), None),
        ("whitespace actor", " \t\n".to_string(), None),
        ("multibyte actor over byte limit", "🦀".repeat(100), None),
        (
            "empty reason",
            "operator-1".to_string(),
            Some(String::new()),
        ),
        (
            "whitespace reason",
            "operator-1".to_string(),
            Some(" \t\n".to_string()),
        ),
        (
            "multibyte reason over byte limit",
            "operator-1".to_string(),
            Some("🦀".repeat(100)),
        ),
    ] {
        let result = db.connection().execute(
            "UPDATE task_board_items SET
                 triage_override_verdict = 'todo',
                 triage_override_actor = ?1,
                 triage_override_reason = ?2,
                 triage_override_set_at = '2026-07-22T00:00:00Z'
             WHERE item_id = 'item-1'",
            (&actor, reason.as_deref()),
        );
        assert!(
            result.is_err(),
            "{name} must be rejected by the CHECK constraint"
        );
    }

    let coherent = db.connection().execute(
        "UPDATE task_board_items SET
             triage_override_verdict = 'todo',
             triage_override_actor = 'operator-1',
             triage_override_reason = 'looks fine',
             triage_override_set_at = '2026-07-22T00:00:00Z'
         WHERE item_id = 'item-1'",
        [],
    );
    assert!(
        coherent.is_ok(),
        "a fully coherent override row must be accepted"
    );
}

#[test]
fn v47_restart_rejects_noncanonical_override_values_that_sql_accepts() {
    for (name, actor, reason, set_at) in [
        (
            "control actor",
            "operator\n1".to_string(),
            None,
            "2026-07-22T00:00:00Z".to_string(),
        ),
        (
            "control reason",
            "operator-1".to_string(),
            Some("bad\nreason".to_string()),
            "2026-07-22T00:00:00Z".to_string(),
        ),
        (
            "impossible timestamp",
            "operator-1".to_string(),
            None,
            "2026-13-40T25:61:61Z".to_string(),
        ),
    ] {
        assert_restart_rejects_override(name, &actor, reason.as_deref(), &set_at);
    }
}

#[test]
fn v47_restart_rejects_a_partial_override_tuple() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current database");
    seed_task_board_item(&db);
    db.connection()
        .execute_batch(
            "PRAGMA ignore_check_constraints = ON;
             UPDATE task_board_items
             SET triage_override_actor = 'operator-1'
             WHERE item_id = 'item-1';
             PRAGMA ignore_check_constraints = OFF;",
        )
        .expect("install partial override tuple");
    drop(db);

    let error = match DaemonDb::open(&path) {
        Ok(_) => panic!("partial override must fail closed on restart"),
        Err(error) => error,
    };
    assert!(
        error.to_string().contains("override is not canonical"),
        "unexpected error: {error}"
    );
}

fn assert_restart_rejects_override(name: &str, actor: &str, reason: Option<&str>, set_at: &str) {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current database");
    seed_task_board_item(&db);
    db.connection()
        .execute(
            "UPDATE task_board_items SET
                 triage_override_verdict = 'todo',
                 triage_override_actor = ?1,
                 triage_override_reason = ?2,
                 triage_override_set_at = ?3
             WHERE item_id = 'item-1'",
            (actor, reason, set_at),
        )
        .unwrap_or_else(|error| panic!("SQL should accept {name}: {error}"));
    drop(db);

    let error = match DaemonDb::open(&path) {
        Ok(_) => panic!("{name} must fail closed on restart"),
        Err(error) => error,
    };
    assert!(
        error.to_string().contains("override is not canonical"),
        "unexpected {name} error: {error}"
    );
}

fn seed_task_board_item(db: &DaemonDb) {
    db.connection()
        .execute(
            "INSERT INTO task_board_items (
                 item_id, schema_version, title, body, status, priority, tags_json,
                 project_id, target_project_types_json, agent_mode, imported_from_provider,
                 planning_json, workflow_json, session_id, work_item_id, usage_json,
                 created_at, updated_at, deleted_at, revision, workflow_kind
             ) VALUES (
                 'item-1', 1, 'Title', '', 'backlog', 'medium', '[]',
                 NULL, '[]', 'headless', NULL, '{}', '{}', NULL, NULL, '{}',
                 '2026-07-22T00:00:00Z', '2026-07-22T00:00:00Z', NULL, 1,
                 'default_task'
             )",
            [],
        )
        .expect("seed one task board item");
}
