use tempfile::tempdir;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};

const DROP_V48_SQL: &str = "
ALTER TABLE task_board_triage_decisions RENAME TO task_board_triage_decisions_v48;
CREATE TABLE task_board_triage_decisions (
    decision_id            TEXT PRIMARY KEY CHECK (length(decision_id) > 0),
    item_id                TEXT NOT NULL,
    generation             INTEGER NOT NULL
                               CHECK (typeof(generation) = 'integer' AND generation > 0),
    verdict                TEXT NOT NULL CHECK (verdict IN ('todo', 'undecided')),
    reason_code            TEXT NOT NULL
                               CHECK (
                                   reason_code IN (
                                       'needs_info_label', 'no_meaningful_labels', 'meaningful_label'
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
FROM task_board_triage_decisions_v48;
DROP TABLE task_board_triage_decisions_v48;
CREATE UNIQUE INDEX task_board_triage_decisions_current
    ON task_board_triage_decisions(item_id)
    WHERE is_current = 1;
CREATE INDEX task_board_triage_decisions_item_history
    ON task_board_triage_decisions(item_id, generation DESC, decided_at DESC);
DROP TABLE task_board_triage_rule_set_draft;
DROP TABLE task_board_triage_rule_set_revisions;
DROP TABLE task_board_triage_rule_set_audit;
UPDATE schema_meta SET value = '47' WHERE key = 'version';";

fn triage_rule_set_table_count(db: &DaemonDb) -> i64 {
    db.connection()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN (
                 'task_board_triage_rule_set_draft', 'task_board_triage_rule_set_revisions',
                 'task_board_triage_rule_set_audit'
             )",
            [],
            |row| row.get(0),
        )
        .expect("count triage rule set tables")
}

#[test]
fn fresh_schema_includes_v48_triage_rule_set_objects() {
    let db = DaemonDb::open_in_memory().expect("open current database");

    assert_eq!(
        db.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    assert_eq!(triage_rule_set_table_count(&db), 3);
}

#[test]
fn v47_database_migrates_to_v48_and_restarts() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current database");
    db.connection()
        .execute_batch(DROP_V48_SQL)
        .expect("restore v47 schema");
    drop(db);

    let reopened = DaemonDb::open(&path).expect("migrate v47 database");
    assert_eq!(
        reopened.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    assert_eq!(triage_rule_set_table_count(&reopened), 3);
    drop(reopened);

    let restarted = DaemonDb::open(&path).expect("restart migrated database");
    assert_eq!(
        restarted.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
}

#[tokio::test]
async fn async_upgrade_records_v48_migration() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current v47 database");
    db.connection()
        .execute_batch(DROP_V48_SQL)
        .expect("restore v47 schema");
    drop(db);

    let async_db = AsyncDaemonDb::connect(&path)
        .await
        .expect("upgrade v47 database asynchronously");

    assert_eq!(
        async_db.schema_version().await.expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
}
