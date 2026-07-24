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

fn migrated_from_v48(path: &std::path::Path, seed: &str) -> DaemonDb {
    let db = DaemonDb::open(path).expect("open current database");
    db.connection()
        .execute_batch(DROP_V51_SQL)
        .expect("restore v48 schema");
    db.connection().execute_batch(seed).expect("seed v48 rows");
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
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'task_board_projects'",
            [],
            |row| row.get(0),
        )
        .expect("count projects table");
    assert_eq!(count, 1);
}

#[test]
fn backfill_gives_every_attributed_item_a_project_identifier() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let migrated = migrated_from_v48(&path, SEED_LEGACY_ITEMS_SQL);
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
    let migrated = migrated_from_v48(&path, SEED_LEGACY_ITEMS_SQL);
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
    let migrated = migrated_from_v48(&path, SEED_LEGACY_ITEMS_SQL);
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
        .expect("restore v48 schema");
    drop(db);

    let async_db = AsyncDaemonDb::connect(&path)
        .await
        .expect("upgrade v50 database asynchronously");

    assert_eq!(
        async_db.schema_version().await.expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
}
