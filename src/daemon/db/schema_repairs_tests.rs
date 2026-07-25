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

/// An index is the easiest object to lose and the hardest to notice: queries
/// still answer, just slowly. Repair has to rebuild it even though the column
/// it covers is already there, which is the path that only stamps the version.
#[test]
fn repair_rebuilds_a_dropped_attribution_index() {
    let db = DaemonDb::open_in_memory().expect("open current database");
    db.conn
        .execute_batch("DROP INDEX task_board_items_source_project;")
        .expect("drop the attribution index");

    repair_current_schema_shape(&db).expect("repair schema shape");

    let restored: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master \
             WHERE type = 'index' AND name = 'task_board_items_source_project'",
            [],
            |row| row.get(0),
        )
        .expect("count the attribution index");
    assert_eq!(restored, 1, "repair left the attribution index missing");
}
