use rusqlite::Connection;
use tempfile::tempdir;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::task_board::project::is_project_id;

const DROP_V51_SQL: &str = "
DROP INDEX IF EXISTS task_board_items_source_project;
DROP INDEX IF EXISTS task_board_projects_source_slug;
ALTER TABLE task_board_items DROP COLUMN source_project_id;
DROP TABLE task_board_projects;
UPDATE schema_meta SET value = '50' WHERE key = 'version';";

const SEED_LEGACY_ITEMS_SQL: &str = "
INSERT INTO task_board_items (
    item_id, schema_version, title, body, status, priority, tags_json, project_id,
    target_project_types_json, agent_mode, workflow_kind, execution_repository,
    imported_from_provider, planning_json, workflow_json, usage_json, child_order,
    created_at, updated_at, revision, kind
) VALUES
    ('imported-github', 1, 'Imported', '', 'todo', 'medium', '[]', NULL,
     '[]', 'headless', 'default_task', 'Acme/Widgets',
     'github', '{}', '{}', '{}', 0,
     '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z', 1, 'task'),
    ('legacy-slug', 1, 'Legacy slug', '', 'todo', 'medium', '[]', 'acme/widgets',
     '[]', 'headless', 'default_task', NULL,
     NULL, '{}', '{}', '{}', 0,
     '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z', 1, 'task'),
    ('todoist-item', 1, 'Todoist', '', 'todo', 'medium', '[]', '2334Ab',
     '[]', 'headless', 'default_task', NULL,
     'todoist', '{}', '{}', '{}', 0,
     '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z', 1, 'task'),
    ('spaced-slug', 1, 'Padded slug', '', 'todo', 'medium', '[]', 'Acme / Widgets',
     '[]', 'headless', 'default_task', NULL,
     NULL, '{}', '{}', '{}', 0,
     '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z', 1, 'task'),
    ('unattributed', 1, 'No project', '', 'todo', 'medium', '[]', NULL,
     '[]', 'headless', 'default_task', NULL,
     NULL, '{}', '{}', '{}', 0,
     '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z', 1, 'task');";

/// A legacy row whose project value is longer than the column's CHECK allows.
/// The `INSERT OR IGNORE` skips the unstorable project and the join then finds
/// nothing, so the item lands unattributed. Pinned because the alternative is
/// a migration that refuses to boot over one absurd string.
#[test]
fn the_backfill_skips_a_value_the_column_would_refuse() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let oversize = "z".repeat(300);
    let seed = format!(
        "INSERT INTO task_board_items (
            item_id, schema_version, title, body, status, priority, tags_json, project_id,
            target_project_types_json, agent_mode, workflow_kind, execution_repository,
            imported_from_provider, planning_json, workflow_json, usage_json, child_order,
            created_at, updated_at, revision, kind
        ) VALUES
            ('oversize', 1, 'Oversize', '', 'todo', 'medium', '[]', '{oversize}',
             '[]', 'headless', 'default_task', NULL,
             NULL, '{{}}', '{{}}', '{{}}', 0,
             '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z', 1, 'task');"
    );

    let migrated = migrated_from_v50(&path, &seed);

    assert_eq!(
        source_project_of(migrated.connection(), "oversize"),
        None,
        "an unstorable slug leaves the item unattributed rather than failing the migration"
    );
    assert_eq!(
        migrated.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
}

fn source_project_of(connection: &Connection, item_id: &str) -> Option<String> {
    connection
        .query_row(
            "SELECT source_project_id FROM task_board_items WHERE item_id = ?1",
            [item_id],
            |row| row.get(0),
        )
        .expect("read item source project")
}

fn slug_of(connection: &Connection, project_id: &str) -> (String, String) {
    connection
        .query_row(
            "SELECT source, slug FROM task_board_projects WHERE project_id = ?1",
            [project_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("read project row")
}

fn migrated_from_v50(path: &std::path::Path, seed: &str) -> DaemonDb {
    let db = DaemonDb::open(path).expect("open current database");
    db.connection()
        .execute_batch(DROP_V51_SQL)
        .expect("restore v50 schema");
    db.connection().execute_batch(seed).expect("seed v50 rows");
    drop(db);
    DaemonDb::open(path).expect("migrate v50 database")
}

#[test]
fn fresh_schema_includes_the_projects_table() {
    let db = DaemonDb::open_in_memory().expect("open current database");

    assert_eq!(
        db.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    let count: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master \
             WHERE type = 'table' AND name = 'task_board_projects'",
            [],
            |row| row.get(0),
        )
        .expect("count projects table");
    assert_eq!(count, 1);
}

/// The column and `is_project_id` have to agree on what an identifier looks
/// like. If the column is the looser of the two, a stored row comes back from
/// every read as an item with no project at all.
#[test]
fn the_projects_table_rejects_an_identifier_is_project_id_would_reject() {
    let db = DaemonDb::open_in_memory().expect("open current database");

    for body in [
        "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ",
        "B43C8448B6FF43A7BC2AD32DB5C558B0",
    ] {
        let candidate = format!("project-{body}");
        assert!(
            !is_project_id(&candidate),
            "{candidate} should not read as an assigned id"
        );
        let stored = db.connection().execute(
            "INSERT INTO task_board_projects (project_id, source, slug, created_at, updated_at)
             VALUES (?1, 'manual', 'rejected', '2026-07-25T00:00:00Z', '2026-07-25T00:00:00Z')",
            [candidate.as_str()],
        );
        assert!(stored.is_err(), "{candidate} was accepted by the column");
    }
}

#[test]
fn backfill_gives_every_attributed_item_a_project_identifier() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let migrated = migrated_from_v50(&path, SEED_LEGACY_ITEMS_SQL);
    let connection = migrated.connection();

    let imported =
        source_project_of(connection, "imported-github").expect("imported item attributed");
    let legacy = source_project_of(connection, "legacy-slug").expect("legacy slug item attributed");
    let todoist = source_project_of(connection, "todoist-item").expect("todoist item attributed");

    assert!(is_project_id(&imported), "{imported} is an assigned id");
    assert_eq!(
        slug_of(connection, &imported),
        ("github".into(), "acme/widgets".into()),
        "the repository is read out of execution_repository and lowercased"
    );
    assert_eq!(
        imported, legacy,
        "the same repository under either legacy column is one project"
    );
    assert_eq!(
        slug_of(connection, &todoist),
        ("todoist".into(), "2334Ab".into()),
        "a provider slug keeps its case"
    );
    assert_ne!(todoist, imported);
    assert_eq!(
        source_project_of(connection, "spaced-slug"),
        Some(imported),
        "the backfill trims each half of a slug exactly like normalize_repository_slug, \
         so padding never splits one repository across two projects"
    );
    assert_eq!(
        source_project_of(connection, "unattributed"),
        None,
        "an item with no origin stays unattributed rather than inventing one"
    );
}

#[test]
fn migration_is_idempotent_across_restarts() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let migrated = migrated_from_v50(&path, SEED_LEGACY_ITEMS_SQL);
    let before = source_project_of(migrated.connection(), "imported-github").expect("attributed");
    drop(migrated);

    let restarted = DaemonDb::open(&path).expect("restart migrated database");
    assert_eq!(
        restarted.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    assert_eq!(
        source_project_of(restarted.connection(), "imported-github"),
        Some(before),
        "a restart neither re-runs the backfill nor reassigns identifiers"
    );
    let projects: i64 = restarted
        .connection()
        .query_row("SELECT COUNT(*) FROM task_board_projects", [], |row| {
            row.get(0)
        })
        .expect("count projects");
    assert_eq!(projects, 2);
}

#[test]
fn renaming_a_project_keeps_its_items_attached() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let migrated = migrated_from_v50(&path, SEED_LEGACY_ITEMS_SQL);
    let connection = migrated.connection();
    let project = source_project_of(connection, "imported-github").expect("attributed");

    connection
        .execute(
            "UPDATE task_board_projects SET slug = 'acme/gadgets' WHERE project_id = ?1",
            [&project],
        )
        .expect("rename project");

    assert_eq!(
        source_project_of(connection, "imported-github"),
        Some(project.clone()),
        "the rename never touches the items"
    );
    assert_eq!(
        slug_of(connection, &project),
        ("github".into(), "acme/gadgets".into())
    );
}

#[tokio::test]
async fn async_upgrade_records_the_v51_migration() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current v50 database");
    db.connection()
        .execute_batch(DROP_V51_SQL)
        .expect("restore v50 schema");
    drop(db);

    let async_db = AsyncDaemonDb::connect(&path)
        .await
        .expect("upgrade v50 database asynchronously");

    assert_eq!(
        async_db.schema_version().await.expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
}
