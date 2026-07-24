use tempfile::tempdir;

use super::shape_needs_repair;
use crate::daemon::db::DaemonDb;

#[test]
fn fresh_v49_database_reopens_without_a_shape_repair_error() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open fresh database");
    drop(db);

    let reopened = DaemonDb::open(&path).expect("reopen v49 database");
    assert!(!shape_needs_repair(reopened.connection()).expect("shape check"));
}

#[test]
fn a_v48_shaped_triage_decisions_table_is_accepted_as_a_known_good_shape() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open fresh database");
    db.connection()
        .execute_batch(
            "ALTER TABLE task_board_triage_decisions RENAME TO task_board_triage_decisions_v49;
             CREATE TABLE task_board_triage_decisions (
                 decision_id            TEXT PRIMARY KEY CHECK (length(decision_id) > 0),
                 item_id                TEXT NOT NULL,
                 generation             INTEGER NOT NULL
                                            CHECK (typeof(generation) = 'integer' AND generation > 0),
                 verdict                TEXT NOT NULL CHECK (verdict IN ('todo', 'undecided')),
                 reason_code            TEXT NOT NULL
                                            CHECK (
                                                reason_code IN (
                                                    'needs_info_label', 'no_meaningful_labels',
                                                    'meaningful_label', 'rule_matched', 'rule_set_default'
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
             INSERT INTO task_board_triage_decisions SELECT * FROM task_board_triage_decisions_v49;
             DROP TABLE task_board_triage_decisions_v49;
             CREATE UNIQUE INDEX task_board_triage_decisions_current
                 ON task_board_triage_decisions(item_id) WHERE is_current = 1;
             CREATE INDEX task_board_triage_decisions_item_history
                 ON task_board_triage_decisions(item_id, generation DESC, decided_at DESC);",
        )
        .expect("downgrade decisions table to the v48 shape");

    assert!(!shape_needs_repair(db.connection()).expect("v48 shape must be accepted as known-good"));
}

#[test]
fn a_genuinely_corrupt_triage_decisions_shape_is_still_rejected() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open fresh database");
    db.connection()
        .execute_batch(
            "ALTER TABLE task_board_triage_decisions RENAME TO task_board_triage_decisions_shadow;
             CREATE TABLE task_board_triage_decisions (decision_id TEXT PRIMARY KEY);",
        )
        .expect("corrupt the triage decisions shape");

    let error = shape_needs_repair(db.connection()).expect_err("corrupt shape must be rejected");
    assert!(format!("{error}").contains("refusing destructive repair"));
}
