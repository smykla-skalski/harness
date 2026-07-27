use tempfile::tempdir;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};

const DROP_V49_SQL: &str = "
ALTER TABLE task_board_triage_decisions RENAME TO task_board_triage_decisions_v49;
CREATE TABLE task_board_triage_decisions (
    decision_id            TEXT PRIMARY KEY CHECK (length(decision_id) > 0),
    item_id                TEXT NOT NULL,
    generation             INTEGER NOT NULL
                               CHECK (typeof(generation) = 'integer' AND generation > 0),
    verdict                TEXT NOT NULL CHECK (verdict IN ('todo', 'undecided')),
    reason_code            TEXT NOT NULL
                               CHECK (
                                   reason_code IN (
                                       'needs_info_label', 'no_meaningful_labels', 'meaningful_label',
                                       'rule_matched', 'rule_set_default'
                                   )
                               ),
    reason_detail          TEXT
                               CHECK (reason_detail IS NULL OR length(reason_detail) <= 256),
    evaluator_identity     TEXT NOT NULL
                               CHECK (length(evaluator_identity) > 0 AND length(evaluator_identity) <= 256),
    evaluator_version      INTEGER NOT NULL
                               CHECK (typeof(evaluator_version) = 'integer' AND evaluator_version > 0),
    evidence_fingerprint   TEXT NOT NULL
                               CHECK (
                                   substr(evidence_fingerprint, 1, 7) = 'sha256:'
                                   AND length(evidence_fingerprint) = 71
                               ),
    cause                  TEXT NOT NULL
                               CHECK (cause IN ('initial', 'fingerprint_changed', 'active_evaluator_changed')),
    decided_at             TEXT NOT NULL CHECK (decided_at GLOB '????-??-??T??:??:??Z'),
    is_current             INTEGER NOT NULL DEFAULT 1 CHECK (is_current IN (0, 1)),
    superseded_at          TEXT
                               CHECK (
                                   superseded_at IS NULL
                                   OR superseded_at GLOB '????-??-??T??:??:??Z'
                               ),
    CHECK (
        (is_current = 1 AND superseded_at IS NULL)
        OR (is_current = 0 AND superseded_at IS NOT NULL AND superseded_at >= decided_at)
    ),
    UNIQUE(item_id, generation),
    FOREIGN KEY (item_id) REFERENCES task_board_items(item_id) ON DELETE RESTRICT
) WITHOUT ROWID;
INSERT INTO task_board_triage_decisions (
    decision_id, item_id, generation, verdict, reason_code, reason_detail,
    evaluator_identity, evaluator_version, evidence_fingerprint, cause, decided_at,
    is_current, superseded_at
)
SELECT decision_id, item_id, generation, verdict, reason_code, reason_detail,
       evaluator_identity, evaluator_version, evidence_fingerprint, cause, decided_at,
       is_current, superseded_at
FROM task_board_triage_decisions_v49;
DROP TABLE task_board_triage_decisions_v49;
CREATE UNIQUE INDEX task_board_triage_decisions_current
    ON task_board_triage_decisions(item_id)
    WHERE is_current = 1;
CREATE INDEX task_board_triage_decisions_item_history
    ON task_board_triage_decisions(item_id, generation DESC, decided_at DESC);
DROP TABLE task_board_triage_escalations;
UPDATE schema_meta SET value = '48' WHERE key = 'version';";

/// Seeds one task board item and one triage decision row with every column
/// set to a value distinct from every other column, so a same-arity
/// transposition in the migration's `INSERT ... SELECT` column list (for
/// example `cause` swapped with `reason_detail`) fails a round-trip
/// assertion instead of silently passing over an empty table.
fn seed_one_decision(db: &DaemonDb) {
    db.connection()
        .execute(
            "INSERT INTO task_board_items (
                 item_id, schema_version, title, body, status, priority, tags_json,
                 project_id, target_project_types_json, agent_mode, imported_from_provider,
                 planning_json, workflow_json, session_id, work_item_id, usage_json,
                 created_at, updated_at, deleted_at, revision, workflow_kind
             ) VALUES (
                 'item-1', 1, 'Title', '', 'inbox', 'medium', '[]',
                 NULL, '[]', 'headless', NULL, '{}', '{}', NULL, NULL, '{}',
                 '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z', NULL, 1,
                 'default_task'
             )",
            [],
        )
        .expect("seed one task board item");
    db.connection()
        .execute(
            "INSERT INTO task_board_triage_decisions (
                 decision_id, item_id, generation, verdict, reason_code, reason_detail,
                 evaluator_identity, evaluator_version, evidence_fingerprint, cause, decided_at,
                 is_current, superseded_at
             ) VALUES (
                 'decision-round-trip-1', 'item-1', 1, 'todo', 'rule_matched', 'urgent-bug-rule',
                 'task_board.triage.rules_v1', 3,
                 'sha256:0000000000000000000000000000000000000000000000000000000000000001',
                 'fingerprint_changed', '2026-07-24T00:00:01Z', 1, NULL
             )",
            [],
        )
        .expect("seed one triage decision");
}

fn assert_seeded_decision_round_tripped(db: &DaemonDb) {
    #[expect(clippy::type_complexity, reason = "one full decision row, positionally")]
    let row: (
        String,
        String,
        i64,
        String,
        String,
        Option<String>,
        String,
        i64,
        String,
        String,
        String,
        i64,
        Option<String>,
    ) = db
        .connection()
        .query_row(
            "SELECT decision_id, item_id, generation, verdict, reason_code, reason_detail,
                    evaluator_identity, evaluator_version, evidence_fingerprint, cause, decided_at,
                    is_current, superseded_at
             FROM task_board_triage_decisions WHERE decision_id = 'decision-round-trip-1'",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                    row.get(8)?,
                    row.get(9)?,
                    row.get(10)?,
                    row.get(11)?,
                    row.get(12)?,
                ))
            },
        )
        .expect("load round-tripped decision");
    assert_eq!(row.1, "item-1");
    assert_eq!(row.2, 1);
    assert_eq!(row.3, "todo");
    assert_eq!(row.4, "rule_matched");
    assert_eq!(row.5.as_deref(), Some("urgent-bug-rule"));
    assert_eq!(row.6, "task_board.triage.rules_v1");
    assert_eq!(row.7, 3);
    assert_eq!(
        row.8,
        "sha256:0000000000000000000000000000000000000000000000000000000000000001"
    );
    assert_eq!(row.9, "fingerprint_changed");
    assert_eq!(row.10, "2026-07-24T00:00:01Z");
    assert_eq!(row.11, 1);
    assert_eq!(row.12, None);
}

fn escalations_table_count(db: &DaemonDb) -> i64 {
    db.connection()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'
                 AND name = 'task_board_triage_escalations'",
            [],
            |row| row.get(0),
        )
        .expect("count escalations table")
}

#[test]
fn fresh_schema_includes_v49_triage_escalations_table() {
    let db = DaemonDb::open_in_memory().expect("open current database");

    assert_eq!(
        db.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    assert_eq!(escalations_table_count(&db), 1);
}

#[test]
fn v48_database_migrates_to_v49_and_restarts() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current database");
    seed_one_decision(&db);
    db.connection()
        .execute_batch(DROP_V49_SQL)
        .expect("restore v48 schema");
    drop(db);

    let reopened = DaemonDb::open(&path).expect("migrate v48 database");
    assert_eq!(
        reopened.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    assert_eq!(escalations_table_count(&reopened), 1);
    assert_seeded_decision_round_tripped(&reopened);
    drop(reopened);

    let restarted = DaemonDb::open(&path).expect("restart migrated database");
    assert_eq!(
        restarted.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    assert_seeded_decision_round_tripped(&restarted);
}

#[tokio::test]
async fn async_upgrade_records_v49_migration() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current v48 database");
    seed_one_decision(&db);
    db.connection()
        .execute_batch(DROP_V49_SQL)
        .expect("restore v48 schema");
    drop(db);

    let async_db = AsyncDaemonDb::connect(&path)
        .await
        .expect("upgrade v48 database asynchronously");

    assert_eq!(
        async_db.schema_version().await.expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    let sync_db = DaemonDb::open(&path).expect("reopen synchronously to verify round-trip");
    assert_eq!(escalations_table_count(&sync_db), 1);
    assert_seeded_decision_round_tripped(&sync_db);
}
