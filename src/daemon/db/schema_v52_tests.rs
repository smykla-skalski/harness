use rusqlite::Connection;
use tempfile::tempdir;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::task_board::project_color::TaskBoardProjectColor;

const DROP_V52_SQL: &str = "
ALTER TABLE task_board_projects DROP COLUMN color;
UPDATE schema_meta SET value = '51' WHERE key = 'version';";

/// Two more projects than the palette holds, so the wrap is exercised rather
/// than assumed. `created_at` is distinct and ascending because that is the
/// order the backfill walks.
fn seed_projects_sql(count: usize) -> String {
    let rows: Vec<String> = (0..count)
        .map(|index| {
            format!(
                "('project-{index:032x}', 'manual', 'project-{index}', NULL, \
                 '2026-07-25T00:00:{index:02}Z', '2026-07-25T00:00:{index:02}Z')"
            )
        })
        .collect();
    format!(
        "INSERT INTO task_board_projects \
         (project_id, source, slug, display_name, created_at, updated_at) VALUES {};",
        rows.join(", ")
    )
}

fn migrated_from_v51(path: &std::path::Path, seed: &str) -> DaemonDb {
    let db = DaemonDb::open(path).expect("open current database");
    db.connection()
        .execute_batch(DROP_V52_SQL)
        .expect("restore v51 schema");
    db.connection().execute_batch(seed).expect("seed v51 rows");
    drop(db);
    DaemonDb::open(path).expect("migrate v51 database")
}

fn colors_in_seed_order(connection: &Connection, count: usize) -> Vec<String> {
    (0..count)
        .map(|index| {
            connection
                .query_row(
                    "SELECT color FROM task_board_projects WHERE project_id = ?1",
                    [format!("project-{index:032x}")],
                    |row| row.get::<_, Option<String>>(0),
                )
                .expect("read project color")
                .unwrap_or_else(|| panic!("project {index} was left without a color"))
        })
        .collect()
}

/// The board's whole point is telling projects apart at a glance, so the
/// backfill has to spend the palette before it repeats itself.
#[test]
fn backfill_gives_every_project_a_color_and_repeats_only_once_out_of_room() {
    let palette = TaskBoardProjectColor::PALETTE;
    let count = palette.len() + 2;
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");

    let migrated = migrated_from_v51(&path, &seed_projects_sql(count));
    let colors = colors_in_seed_order(migrated.connection(), count);

    let expected: Vec<String> = (0..count)
        .map(|index| palette[index % palette.len()].as_str().to_owned())
        .collect();
    assert_eq!(
        colors, expected,
        "the backfill walks the palette in order and wraps only after using all of it"
    );
    let mut distinct = colors[..palette.len()].to_vec();
    distinct.sort();
    distinct.dedup();
    assert_eq!(
        distinct.len(),
        palette.len(),
        "two projects shared a color while the palette still had room"
    );
}

/// The palette lives in Rust and in the migration's `VALUES` list, and the two
/// have to name the same colors in the same order. Reading both here means
/// adding a color cannot silently leave the backfill handing out a name the
/// runtime does not know.
#[test]
fn migration_backfill_matches_the_palette() {
    let listed: Vec<(usize, String)> = super::COLOR_BACKFILL_SQL
        .lines()
        .filter_map(|line| {
            let (slot, rest) = line.trim().strip_prefix('(')?.split_once(", '")?;
            Some((slot.parse::<usize>().ok()?, rest.split('\'').next()?.to_owned()))
        })
        .collect();

    let expected: Vec<(usize, String)> = TaskBoardProjectColor::PALETTE
        .iter()
        .enumerate()
        .map(|(slot, color)| (slot, color.as_str().to_owned()))
        .collect();
    assert_eq!(
        listed, expected,
        "the migration's palette drifted from TaskBoardProjectColor::PALETTE"
    );
}

#[test]
fn fresh_schema_carries_the_color_column() {
    let db = DaemonDb::open_in_memory().expect("open current database");

    assert_eq!(
        db.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    let count: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_projects') WHERE name = 'color'",
            [],
            |row| row.get(0),
        )
        .expect("count color column");
    assert_eq!(count, 1);
}

/// A color a person chose has to survive the next boot, which means the
/// backfill can only ever touch rows that have none.
#[test]
fn a_restart_leaves_an_assigned_color_alone() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let migrated = migrated_from_v51(&path, &seed_projects_sql(3));
    migrated
        .connection()
        .execute(
            "UPDATE task_board_projects SET color = 'graphite' WHERE project_id = ?1",
            [format!("project-{:032x}", 0)],
        )
        .expect("choose a color");
    drop(migrated);

    let restarted = DaemonDb::open(&path).expect("restart migrated database");

    assert_eq!(
        colors_in_seed_order(restarted.connection(), 1),
        vec!["graphite".to_owned()],
        "the backfill reassigned a color that was already chosen"
    );
    assert_eq!(
        restarted.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
}

/// The column takes a shape check rather than the palette itself, so that
/// adding a color stays a code change. It still has to refuse a value nothing
/// could ever render.
#[test]
fn the_color_column_refuses_a_shapeless_value() {
    let db = DaemonDb::open_in_memory().expect("open current database");

    for candidate in ["", "Blue", "blue teal", &"z".repeat(33)] {
        let stored = db.connection().execute(
            "INSERT INTO task_board_projects \
             (project_id, source, slug, color, created_at, updated_at) \
             VALUES ('project-0123456789abcdef0123456789abcdef', 'manual', 'shape', ?1, \
                     '2026-07-25T00:00:00Z', '2026-07-25T00:00:00Z')",
            [candidate],
        );
        assert!(stored.is_err(), "'{candidate}' was accepted by the column");
    }
}

#[tokio::test]
async fn async_upgrade_records_the_v52_migration() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current v51 database");
    db.connection()
        .execute_batch(DROP_V52_SQL)
        .expect("restore v51 schema");
    db.connection()
        .execute_batch(&seed_projects_sql(2))
        .expect("seed v51 rows");
    drop(db);

    let async_db = AsyncDaemonDb::connect(&path)
        .await
        .expect("upgrade v51 database asynchronously");

    assert_eq!(
        async_db.schema_version().await.expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
}
