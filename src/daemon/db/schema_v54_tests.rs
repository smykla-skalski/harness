use rusqlite::Connection;
use tempfile::tempdir;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};

/// Puts `task_board_projects` back at its v51 shape so a `source = 'todoist'`
/// row can be seeded at all, then stamps v51 so the next open migrates.
/// `foreign_keys` is suspended for the same reason the migration suspends it:
/// `task_board_items` references this table by name.
const RESTORE_V51_SQL: &str = "
PRAGMA foreign_keys = OFF;
PRAGMA legacy_alter_table = ON;
ALTER TABLE task_board_projects RENAME TO task_board_projects_current;
CREATE TABLE task_board_projects (
    project_id    TEXT PRIMARY KEY,
    source        TEXT NOT NULL CHECK (source IN ('github', 'todoist', 'manual')),
    slug          TEXT NOT NULL,
    display_name  TEXT,
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL,
    UNIQUE(source, slug)
) WITHOUT ROWID;
INSERT INTO task_board_projects SELECT * FROM task_board_projects_current;
DROP TABLE task_board_projects_current;
CREATE INDEX IF NOT EXISTS task_board_projects_source_slug
    ON task_board_projects(source, slug);
PRAGMA legacy_alter_table = OFF;
PRAGMA foreign_keys = ON;
UPDATE schema_meta SET value = '51' WHERE key = 'version';";

const SEED_TODOIST_SQL: &str = "
INSERT INTO task_board_projects (
    project_id, source, slug, display_name, created_at, updated_at
) VALUES
    ('project-00000000000000000000000000000001', 'todoist', '2334Ab', NULL,
     '2026-07-25T00:00:00Z', '2026-07-25T00:00:00Z'),
    ('project-00000000000000000000000000000002', 'github', 'acme/widgets', NULL,
     '2026-07-25T00:00:00Z', '2026-07-25T00:00:00Z');

INSERT INTO task_board_items (
    item_id, schema_version, title, body, status, priority, tags_json, project_id,
    target_project_types_json, agent_mode, workflow_kind, execution_repository,
    imported_from_provider, planning_json, workflow_json, usage_json, child_order,
    created_at, updated_at, revision, kind, source_project_id
) VALUES
    ('imported-todoist', 1, 'Imported', '', 'todo', 'medium', '[]', '2334Ab',
     '[]', 'headless', 'default_task', NULL,
     'todoist', '{}', '{}', '{}', 0,
     '2026-07-25T00:00:00Z', '2026-07-25T00:00:00Z', 1, 'task',
     'project-00000000000000000000000000000001'),
    ('mirrored-board-item', 1, 'Board owned', '', 'todo', 'medium', '[]', NULL,
     '[]', 'headless', 'default_task', 'Acme/Widgets',
     NULL, '{}', '{}', '{}', 0,
     '2026-07-25T00:00:00Z', '2026-07-25T00:00:00Z', 1, 'task',
     'project-00000000000000000000000000000002'),
    ('detached-survivor', 1, 'Attributed to Todoist', '', 'todo', 'medium', '[]', NULL,
     '[]', 'headless', 'default_task', NULL,
     NULL, '{}', '{}', '{}', 0,
     '2026-07-25T00:00:00Z', '2026-07-25T00:00:00Z', 1, 'task',
     'project-00000000000000000000000000000001');

INSERT INTO task_board_external_refs (item_id, position, provider, external_id, url)
VALUES
    ('imported-todoist', 0, 'todoist', '7001', NULL),
    ('mirrored-board-item', 0, 'todoist', '7002', NULL),
    ('mirrored-board-item', 1, 'github', '42', NULL);

INSERT INTO task_board_provider_scope_state (provider, scope_id, updated_at)
VALUES
    ('todoist', '2334Ab', '2026-07-25T00:00:00Z'),
    ('github', 'acme/widgets', '2026-07-25T00:00:00Z');

INSERT INTO task_board_sync_conflicts (
    conflict_id, item_id, provider, external_ref, field,
    base_value_json, local_value_json, remote_value_json,
    item_revision, state, detected_at
) VALUES
    ('conflict-todoist', 'mirrored-board-item', 'todoist', '7002', 'title',
     '\"a\"', '\"b\"', '\"c\"', 1, 'open', '2026-07-25T00:00:00Z'),
    ('conflict-github', 'mirrored-board-item', 'github', '42', 'title',
     '\"a\"', '\"b\"', '\"c\"', 1, 'open', '2026-07-25T00:00:00Z');

INSERT INTO task_board_external_create_intents (
    intent_id, item_id, item_revision, provider, scope_id, create_key, state,
    create_snapshot_json, changed_fields_json, created_at, updated_at
) VALUES
    ('intent-todoist', 'imported-todoist', 1, 'todoist', '2334Ab', 'key-1', 'in_flight',
     '{}', '[]', '2026-07-25T00:00:00Z', '2026-07-25T00:00:00Z'),
    ('intent-github', 'mirrored-board-item', 1, 'github', 'acme/widgets', 'key-2', 'in_flight',
     '{}', '[]', '2026-07-25T00:00:00Z', '2026-07-25T00:00:00Z');

INSERT INTO task_board_triage_decisions (
    decision_id, item_id, generation, verdict, reason_code, evaluator_identity,
    evaluator_version, evidence_fingerprint, cause, decided_at
) VALUES
    ('triage-todoist', 'imported-todoist', 1, 'todo', 'rule_matched', 'seed-evaluator',
     1, 'sha256:0000000000000000000000000000000000000000000000000000000000000000',
     'initial', '2026-07-25T00:00:00Z');";

fn migrated_from_v51(path: &std::path::Path, seed: &str) -> DaemonDb {
    let db = DaemonDb::open(path).expect("open current database");
    db.connection()
        .execute_batch(RESTORE_V51_SQL)
        .expect("restore v51 schema");
    db.connection().execute_batch(seed).expect("seed v51 rows");
    drop(db);
    DaemonDb::open(path).expect("migrate v51 database")
}

fn count(connection: &Connection, sql: &str) -> i64 {
    connection
        .query_row(sql, [], |row| row.get(0))
        .expect("count rows")
}

fn exists(connection: &Connection, table: &str, id_column: &str, id: &str) -> bool {
    connection
        .query_row(
            &format!("SELECT EXISTS(SELECT 1 FROM {table} WHERE {id_column} = ?1)"),
            [id],
            |row| row.get(0),
        )
        .expect("check row")
}

#[test]
fn an_item_imported_from_todoist_is_deleted_with_its_provider_rows() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let migrated = migrated_from_v51(&path, SEED_TODOIST_SQL);
    let connection = migrated.connection();

    assert!(
        !exists(connection, "task_board_items", "item_id", "imported-todoist"),
        "the imported item is gone"
    );
    assert!(
        !exists(
            connection,
            "task_board_external_create_intents",
            "intent_id",
            "intent-todoist"
        ),
        "a RESTRICT child does not survive the item it blocked"
    );
    assert!(
        !exists(
            connection,
            "task_board_triage_decisions",
            "decision_id",
            "triage-todoist"
        ),
        "the triage decision goes with the item"
    );
    assert_eq!(
        count(
            connection,
            "SELECT COUNT(*) FROM task_board_provider_scope_state WHERE provider = 'todoist'"
        ),
        0
    );
    assert_eq!(
        count(
            connection,
            "SELECT COUNT(*) FROM task_board_projects WHERE source = 'todoist'"
        ),
        0
    );
}

/// A board-owned item was only mirrored to Todoist. Deleting it would throw
/// away work nobody asked to lose, so only its Todoist records go.
#[test]
fn a_board_owned_item_keeps_its_row_and_loses_only_its_todoist_records() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let migrated = migrated_from_v51(&path, SEED_TODOIST_SQL);
    let connection = migrated.connection();

    assert!(
        exists(
            connection,
            "task_board_items",
            "item_id",
            "mirrored-board-item"
        ),
        "the board-owned item survives"
    );
    assert_eq!(
        count(
            connection,
            "SELECT COUNT(*) FROM task_board_external_refs WHERE provider = 'todoist'"
        ),
        0,
        "its Todoist ref is gone, and no non-lenient decoder can hit it again"
    );
    assert_eq!(
        count(
            connection,
            "SELECT COUNT(*) FROM task_board_external_refs WHERE provider = 'github'"
        ),
        1,
        "its GitHub ref is untouched"
    );
    assert_eq!(
        count(
            connection,
            "SELECT COUNT(*) FROM task_board_sync_conflicts WHERE provider = 'todoist'"
        ),
        0
    );
    assert_eq!(
        count(
            connection,
            "SELECT COUNT(*) FROM task_board_sync_conflicts WHERE provider = 'github'"
        ),
        1
    );
    assert!(
        exists(
            connection,
            "task_board_external_create_intents",
            "intent_id",
            "intent-github"
        ),
        "the GitHub create intent is untouched"
    );
}

/// An item attributed to a Todoist project is not itself a Todoist item, so it
/// survives detached. Leaving the attribution in place would block the project
/// delete, because `task_board_items` references that table with no action.
#[test]
fn a_survivor_attributed_to_a_todoist_project_is_detached_not_deleted() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let migrated = migrated_from_v51(&path, SEED_TODOIST_SQL);
    let connection = migrated.connection();

    let attribution: Option<String> = connection
        .query_row(
            "SELECT source_project_id FROM task_board_items WHERE item_id = 'detached-survivor'",
            [],
            |row| row.get(0),
        )
        .expect("read survivor attribution");

    assert_eq!(attribution, None, "the survivor reads as unattributed");
    assert_eq!(
        count(
            connection,
            "SELECT COUNT(*) FROM task_board_items \
             WHERE item_id = 'mirrored-board-item' AND source_project_id IS NOT NULL"
        ),
        1,
        "an unrelated attribution is left alone"
    );
}

#[test]
fn the_projects_source_check_no_longer_accepts_todoist() {
    let db = DaemonDb::open_in_memory().expect("open current database");

    let stored = db.connection().execute(
        "INSERT INTO task_board_projects (project_id, source, slug, created_at, updated_at)
         VALUES ('project-000000000000000000000000000000ff', 'todoist', 'rejected',
                 '2026-07-25T00:00:00Z', '2026-07-25T00:00:00Z')",
        [],
    );

    assert!(stored.is_err(), "the column accepted a removed provider");
    assert_eq!(
        db.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
}

/// The rebuild is not expressible as an idempotent statement, so it is guarded
/// on the constraint it changes. Reopening has to leave both the shape and the
/// surviving rows alone.
#[test]
fn migration_is_idempotent_across_restarts() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let migrated = migrated_from_v51(&path, SEED_TODOIST_SQL);
    let before = count(migrated.connection(), "SELECT COUNT(*) FROM task_board_items");
    drop(migrated);

    let reopened = DaemonDb::open(&path).expect("reopen migrated database");

    assert_eq!(
        count(reopened.connection(), "SELECT COUNT(*) FROM task_board_items"),
        before
    );
    assert_eq!(
        count(
            reopened.connection(),
            "SELECT COUNT(*) FROM sqlite_master \
             WHERE type = 'table' AND name = 'task_board_projects'"
        ),
        1,
        "the rebuild ran once and left exactly one table behind"
    );
    assert_eq!(
        count(
            reopened.connection(),
            "SELECT COUNT(*) FROM sqlite_master \
             WHERE type = 'table' AND name LIKE 'task_board_projects_%'"
        ),
        0,
        "no temp table survived the swap"
    );
    assert_eq!(
        reopened.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
}

/// The sync path suspends `foreign_keys` around its own transaction, but the
/// sqlx migrator runs the same file on a connection that enables them, and a
/// rename under enforcement rewrites the referencing clause in
/// `task_board_items` onto the temp table the rebuild then drops. Every insert
/// against a freshly migrated database fails once that happens, so this covers
/// the path the sync tests above cannot reach.
#[tokio::test]
async fn async_migration_leaves_the_items_foreign_key_on_the_live_table() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open async db");

    let items_sql: String = sqlx::query_scalar(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'task_board_items'",
    )
    .fetch_one(db.pool())
    .await
    .expect("task_board_items schema");

    assert!(
        !items_sql.contains("pre_v54"),
        "source_project_id references the dropped rebuild table: {items_sql}"
    );

    // Enforcement is suspended for the whole migrator run, so prove it came
    // back on rather than leaving every later write unchecked.
    let foreign_keys: i64 = sqlx::query_scalar("PRAGMA foreign_keys")
        .fetch_one(db.pool())
        .await
        .expect("foreign_keys pragma");
    assert_eq!(foreign_keys, 1, "migrations left enforcement suspended");
}
