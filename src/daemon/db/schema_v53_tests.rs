use std::collections::{BTreeMap, BTreeSet};

use rusqlite::Connection;
use tempfile::tempdir;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::task_board::project_color::TaskBoardProjectColor;
use crate::task_board::project_shape::{TaskBoardProjectShape, organization_of};

const DROP_V53_SQL: &str = "
ALTER TABLE task_board_projects DROP COLUMN shape;
UPDATE schema_meta SET value = '52' WHERE key = 'version';";

/// `count` projects dealt round-robin across `organizations` owners, so one
/// owner always holds more than one repository and the grouping is exercised
/// rather than assumed.
fn seed_projects_sql(count: usize, organizations: usize) -> String {
    let rows: Vec<String> = (0..count)
        .map(|index| {
            let owner = index % organizations;
            format!(
                "('project-{index:032x}', 'github', 'owner-{owner}/repository-{index}', NULL, \
                 'blue', '2026-07-25T00:00:{index:02}Z', '2026-07-25T00:00:{index:02}Z')"
            )
        })
        .collect();
    format!(
        "INSERT INTO task_board_projects \
         (project_id, source, slug, display_name, color, created_at, updated_at) VALUES {};",
        rows.join(", ")
    )
}

fn migrated_from_v52(path: &std::path::Path, seed: &str) -> DaemonDb {
    let db = DaemonDb::open(path).expect("open current database");
    db.connection()
        .execute_batch(DROP_V53_SQL)
        .expect("restore v52 schema");
    db.connection().execute_batch(seed).expect("seed v52 rows");
    drop(db);
    DaemonDb::open(path).expect("migrate v52 database")
}

fn shapes_by_slug(connection: &Connection) -> BTreeMap<String, Option<String>> {
    let mut statement = connection
        .prepare("SELECT slug, shape FROM task_board_projects ORDER BY slug")
        .expect("prepare shape read");
    let rows = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
        })
        .expect("read shapes");
    rows.map(|row| row.expect("shape row")).collect()
}

/// Below the threshold colour tells every project apart on its own, and an
/// outline nobody needs is noise on every card.
#[test]
fn a_board_the_palette_still_covers_wears_no_shape() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let count = TaskBoardProjectColor::PALETTE.len();

    let migrated = migrated_from_v52(&path, &seed_projects_sql(count, 4));

    let shapes = shapes_by_slug(migrated.connection());
    assert_eq!(shapes.len(), count);
    assert!(
        shapes.values().all(Option::is_none),
        "a board inside the palette was given outlines it does not need"
    );
}

/// Past the palette two projects have to share a colour, so the outline is the
/// only thing left keeping them apart. It follows the owner, because two
/// repositories from one owner are usually two views of the same work.
#[test]
fn crossing_the_palette_assigns_one_shape_per_organization() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let organizations = 5;
    let count = TaskBoardProjectColor::PALETTE.len() + 1;

    let migrated = migrated_from_v52(&path, &seed_projects_sql(count, organizations));

    let shapes = shapes_by_slug(migrated.connection());
    let mut by_organization: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for (slug, shape) in &shapes {
        let shape = shape
            .clone()
            .unwrap_or_else(|| panic!("{slug} was left without a shape past the palette"));
        by_organization
            .entry(organization_of(slug).to_owned())
            .or_default()
            .insert(shape);
    }

    assert_eq!(by_organization.len(), organizations);
    for (organization, assigned) in &by_organization {
        assert_eq!(
            assigned.len(),
            1,
            "{organization} spread across {assigned:?} instead of one outline"
        );
    }
    let distinct: BTreeSet<&String> = by_organization
        .values()
        .filter_map(|assigned| assigned.iter().next())
        .collect();
    assert_eq!(
        distinct.len(),
        organizations,
        "two organizations shared an outline while others were still unused"
    );
}

/// The owner expression lives in SQL and in Rust, and a board that grouped one
/// way in the migration and another at runtime would hand the same project two
/// different outlines.
#[test]
fn migration_groups_by_the_same_organization_rust_does() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let slugs = ["acme/widgets", "acme/gadgets", "solo-project", "beta/thing"];
    let padding = TaskBoardProjectColor::PALETTE.len() + 1 - slugs.len();
    let mut seed = String::from(
        "INSERT INTO task_board_projects \
         (project_id, source, slug, display_name, color, created_at, updated_at) VALUES ",
    );
    let mut rows: Vec<String> = slugs
        .iter()
        .enumerate()
        .map(|(index, slug)| {
            format!(
                "('project-{index:032x}', 'github', '{slug}', NULL, 'blue', \
                 '2026-07-25T00:00:{index:02}Z', '2026-07-25T00:00:{index:02}Z')"
            )
        })
        .collect();
    for index in 0..padding {
        let ordinal = index + slugs.len();
        rows.push(format!(
            "('project-{ordinal:032x}', 'github', 'filler-{ordinal}/repository', NULL, 'blue', \
             '2026-07-25T00:01:{ordinal:02}Z', '2026-07-25T00:01:{ordinal:02}Z')"
        ));
    }
    seed.push_str(&rows.join(", "));
    seed.push(';');

    let migrated = migrated_from_v52(&path, &seed);

    let shapes = shapes_by_slug(migrated.connection());
    assert_eq!(
        shapes["acme/widgets"], shapes["acme/gadgets"],
        "one owner was split across two outlines"
    );
    assert!(
        shapes["solo-project"].is_some(),
        "a slug carrying no owner was left without an outline"
    );
    assert_ne!(
        shapes["acme/widgets"], shapes["beta/thing"],
        "two owners collapsed onto one outline with others unused"
    );
}

/// The shapes live in Rust and in the migration's `VALUES` list, and the two
/// have to name the same outlines in the same order.
#[test]
fn migration_backfill_matches_the_shapes() {
    let listed: Vec<(usize, String)> = super::SHAPE_BACKFILL_SQL
        .lines()
        .filter_map(|line| {
            let (slot, rest) = line.trim().strip_prefix('(')?.split_once(", '")?;
            Some((slot.parse::<usize>().ok()?, rest.split('\'').next()?.to_owned()))
        })
        .collect();

    let expected: Vec<(usize, String)> = TaskBoardProjectShape::SHAPES
        .iter()
        .enumerate()
        .map(|(slot, shape)| (slot, shape.as_str().to_owned()))
        .collect();
    assert_eq!(
        listed, expected,
        "the migration's shapes drifted from TaskBoardProjectShape::SHAPES"
    );
}

/// The threshold is read off the palette rather than written as a number, so a
/// colour added to the palette moves it without anyone remembering to.
#[test]
fn migration_threshold_matches_the_palette_length() {
    let listed = super::SHAPE_BACKFILL_SQL
        .lines()
        .filter(|line| line.trim_start().starts_with('(') && line.contains("'blue'"))
        .count();

    assert_eq!(listed, 1, "the palette list in the shape backfill moved");
    let names = TaskBoardProjectColor::PALETTE
        .iter()
        .filter(|color| super::SHAPE_BACKFILL_SQL.contains(&format!("('{}')", color.as_str())))
        .count();
    assert_eq!(
        names,
        TaskBoardProjectColor::PALETTE.len(),
        "the shape backfill's palette drifted from TaskBoardProjectColor::PALETTE"
    );
}

#[test]
fn fresh_schema_carries_the_shape_column() {
    let db = DaemonDb::open_in_memory().expect("open current database");

    assert_eq!(
        db.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    let count: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_projects') WHERE name = 'shape'",
            [],
            |row| row.get(0),
        )
        .expect("count shape column");
    assert_eq!(count, 1);
}

/// An outline already handed out has to survive the next boot, or a board would
/// reshuffle every time the daemon restarts.
#[test]
fn a_restart_leaves_an_assigned_shape_alone() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let count = TaskBoardProjectColor::PALETTE.len() + 1;
    let migrated = migrated_from_v52(&path, &seed_projects_sql(count, 3));
    migrated
        .connection()
        .execute(
            "UPDATE task_board_projects SET shape = 'pentagon' WHERE project_id = ?1",
            [format!("project-{:032x}", 0)],
        )
        .expect("choose a shape");
    drop(migrated);

    let restarted = DaemonDb::open(&path).expect("restart migrated database");

    let stored: Option<String> = restarted
        .connection()
        .query_row(
            "SELECT shape FROM task_board_projects WHERE project_id = ?1",
            [format!("project-{:032x}", 0)],
            |row| row.get(0),
        )
        .expect("read shape");
    assert_eq!(stored, Some("pentagon".to_owned()));
}

#[test]
fn the_shape_column_refuses_a_shapeless_value() {
    let db = DaemonDb::open_in_memory().expect("open current database");

    for candidate in ["", "Circle", "circle square", &"z".repeat(33)] {
        let stored = db.connection().execute(
            "INSERT INTO task_board_projects \
             (project_id, source, slug, shape, created_at, updated_at) \
             VALUES ('project-0123456789abcdef0123456789abcdef', 'manual', 'shape', ?1, \
                     '2026-07-25T00:00:00Z', '2026-07-25T00:00:00Z')",
            [candidate],
        );
        assert!(stored.is_err(), "'{candidate}' was accepted by the column");
    }
}

#[tokio::test]
async fn async_upgrade_records_the_v53_migration() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current v52 database");
    db.connection()
        .execute_batch(DROP_V53_SQL)
        .expect("restore v52 schema");
    db.connection()
        .execute_batch(&seed_projects_sql(2, 1))
        .expect("seed v52 rows");
    drop(db);

    let async_db = AsyncDaemonDb::connect(&path)
        .await
        .expect("upgrade v52 database asynchronously");

    assert_eq!(
        async_db.schema_version().await.expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
}
