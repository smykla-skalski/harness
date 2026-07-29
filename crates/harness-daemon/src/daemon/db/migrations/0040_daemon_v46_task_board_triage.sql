ALTER TABLE task_board_items ADD COLUMN tombstone_cause TEXT
    CONSTRAINT task_board_items_tombstone_cause_values
    CHECK (
        tombstone_cause IS NULL
        OR (deleted_at IS NOT NULL AND tombstone_cause IN ('manual', 'provider_exclusion'))
    );

CREATE TABLE IF NOT EXISTS task_board_triage_decisions (
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

CREATE UNIQUE INDEX IF NOT EXISTS task_board_triage_decisions_current
    ON task_board_triage_decisions(item_id)
    WHERE is_current = 1;

CREATE INDEX IF NOT EXISTS task_board_triage_decisions_item_history
    ON task_board_triage_decisions(item_id, generation DESC, decided_at DESC);

UPDATE schema_meta SET value = '46' WHERE key = 'version';
