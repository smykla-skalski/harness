use super::repair_current_schema_shape;
use crate::daemon::db::{DaemonDb, SCHEMA_VERSION};

/// The repair chain stamps `SCHEMA_VERSION` unconditionally, so it has to
/// replay every version up to it. A migration left out of the chain marks a
/// damaged database as current while its shape is still missing, and nothing
/// downstream ever looks again.
#[test]
fn repair_restores_the_newest_schema_objects_before_stamping() {
    let db = DaemonDb::open_in_memory().expect("open current database");
    db.conn
        .execute_batch("DROP TABLE task_board_projects;")
        .expect("drop the newest table");

    repair_current_schema_shape(&db).expect("repair schema shape");

    let restored: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master \
             WHERE type = 'table' AND name = 'task_board_projects'",
            [],
            |row| row.get(0),
        )
        .expect("count the projects table");
    assert_eq!(restored, 1, "repair left the newest table missing");
    assert_eq!(db.schema_version().expect("schema version"), SCHEMA_VERSION);
}

/// Same trap one version on. The chain stamps the current version whatever it
/// finds, so a column added by the newest migration and then lost reads as a
/// current database that no card can draw a project mark from.
#[test]
fn repair_restores_a_dropped_column_and_fills_it() {
    let db = DaemonDb::open_in_memory().expect("open current database");
    db.conn
        .execute_batch(
            "INSERT INTO task_board_projects \
             (project_id, source, slug, created_at, updated_at) \
             VALUES ('project-0123456789abcdef0123456789abcdef', 'manual', 'kept', \
                     '2026-07-25T00:00:00Z', '2026-07-25T00:00:00Z'); \
             ALTER TABLE task_board_projects DROP COLUMN color;",
        )
        .expect("drop the newest column");

    repair_current_schema_shape(&db).expect("repair schema shape");

    let color: Option<String> = db
        .conn
        .query_row(
            "SELECT color FROM task_board_projects WHERE project_id = ?1",
            ["project-0123456789abcdef0123456789abcdef"],
            |row| row.get(0),
        )
        .expect("read the restored column");
    assert!(
        color.is_some(),
        "repair restored the column but left the project without a color"
    );
    assert_eq!(db.schema_version().expect("schema version"), SCHEMA_VERSION);
}

/// An index is the easiest object to lose and the hardest to notice: queries
/// still answer, just slowly. Repair has to rebuild one even though the column
/// it covers is already there, which is the path that only stamps the version.
/// Every v51 index is covered, because detecting one and not its sibling is
/// how the second went unrepairable.
#[test]
fn repair_rebuilds_a_dropped_index() {
    for index in [
        "task_board_items_source_project",
        "task_board_projects_source_slug",
    ] {
        let db = DaemonDb::open_in_memory().expect("open current database");
        db.conn
            .execute_batch(&format!("DROP INDEX {index};"))
            .unwrap_or_else(|error| panic!("drop {index}: {error}"));

        repair_current_schema_shape(&db).expect("repair schema shape");

        let restored: i64 = db
            .conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?1",
                [index],
                |row| row.get(0),
            )
            .unwrap_or_else(|error| panic!("count {index}: {error}"));
        assert_eq!(restored, 1, "repair left {index} missing");
    }
}
