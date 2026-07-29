ALTER TABLE task_board_triage_decisions RENAME TO task_board_triage_decisions_v47;

CREATE TABLE IF NOT EXISTS task_board_triage_decisions (
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
FROM task_board_triage_decisions_v47;

DROP TABLE task_board_triage_decisions_v47;

CREATE UNIQUE INDEX IF NOT EXISTS task_board_triage_decisions_current
    ON task_board_triage_decisions(item_id)
    WHERE is_current = 1;

CREATE INDEX IF NOT EXISTS task_board_triage_decisions_item_history
    ON task_board_triage_decisions(item_id, generation DESC, decided_at DESC);

-- Mutable single-slot draft candidate. Not itself part of the immutable
-- version history; `revision` here is only a per-draft CAS token for
-- concurrent-editor safety, unrelated to activated rule-set revisions below.
CREATE TABLE IF NOT EXISTS task_board_triage_rule_set_draft (
    singleton   INTEGER PRIMARY KEY CHECK (singleton = 1),
    rules_json  TEXT NOT NULL,
    revision    INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
    actor       TEXT NOT NULL CHECK (length(trim(actor)) > 0 AND length(CAST(actor AS BLOB)) <= 256),
    updated_at  TEXT NOT NULL CHECK (updated_at GLOB '????-??-??T??:??:??Z')
);

-- Append-only, immutable activation history. At most one row is ever
-- `active`; zero active rows means `BuiltInV1` governs by default.
CREATE TABLE IF NOT EXISTS task_board_triage_rule_set_revisions (
    revision        INTEGER PRIMARY KEY CHECK (revision > 0),
    schema_version  INTEGER NOT NULL CHECK (schema_version > 0),
    rules_json      TEXT NOT NULL,
    status          TEXT NOT NULL CHECK (status IN ('active', 'superseded')),
    actor           TEXT NOT NULL CHECK (length(trim(actor)) > 0 AND length(CAST(actor AS BLOB)) <= 256),
    activated_at    TEXT NOT NULL CHECK (activated_at GLOB '????-??-??T??:??:??Z'),
    superseded_at   TEXT CHECK (superseded_at IS NULL OR superseded_at GLOB '????-??-??T??:??:??Z'),
    CHECK (
        (status = 'active' AND superseded_at IS NULL)
        OR (status = 'superseded' AND superseded_at IS NOT NULL AND superseded_at >= activated_at)
    )
) WITHOUT ROWID;

CREATE UNIQUE INDEX IF NOT EXISTS task_board_triage_rule_set_revisions_active
    ON task_board_triage_rule_set_revisions(status)
    WHERE status = 'active';

-- Typed audit evidence for every activation attempt, including a rejected
-- one -- a rejection never touches the two tables above, so this is the
-- only durable record a malformed or contradictory candidate ever existed.
CREATE TABLE IF NOT EXISTS task_board_triage_rule_set_audit (
    audit_id                TEXT PRIMARY KEY CHECK (length(audit_id) > 0),
    kind                    TEXT NOT NULL
                                CHECK (kind IN ('activated', 'activation_rejected', 'deactivated')),
    revision                INTEGER,
    actor                   TEXT NOT NULL
                                CHECK (length(trim(actor)) > 0 AND length(CAST(actor AS BLOB)) <= 256),
    reason                  TEXT CHECK (reason IS NULL OR length(CAST(reason AS BLOB)) <= 1024),
    validation_json         TEXT,
    reevaluated_item_count  INTEGER CHECK (reevaluated_item_count IS NULL OR reevaluated_item_count >= 0),
    recorded_at             TEXT NOT NULL CHECK (recorded_at GLOB '????-??-??T??:??:??Z')
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS task_board_triage_rule_set_audit_recorded_at
    ON task_board_triage_rule_set_audit(recorded_at DESC);

UPDATE schema_meta SET value = '48' WHERE key = 'version';
