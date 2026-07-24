ALTER TABLE task_board_triage_decisions RENAME TO task_board_triage_decisions_v48;

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
                                       'rule_matched', 'rule_set_default', 'agent_verdict'
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

CREATE UNIQUE INDEX IF NOT EXISTS task_board_triage_decisions_current
    ON task_board_triage_decisions(item_id)
    WHERE is_current = 1;

CREATE INDEX IF NOT EXISTS task_board_triage_decisions_item_history
    ON task_board_triage_decisions(item_id, generation DESC, decided_at DESC);

-- Mutable single-row-per-request lifecycle, modeled on
-- `task_board_dispatch_intents`: 'pending' -> 'running' -> one terminal
-- state. Unlike `task_board_triage_decisions` this is not an append-only
-- history -- at most one live (pending/running) row exists per item at a
-- time (enforced below), and a superseded/terminal row is simply left in
-- place as its own audit trail entry rather than being copied anywhere.
--
-- Lifecycle shape:
--   pending:                started_at, verdict_token, managed_run_id all NULL; completed_at NULL.
--   running:                started_at, verdict_token, managed_run_id all NOT NULL; completed_at NULL.
--   succeeded/failed/timed_out/rejected (always reached from running):
--                            started_at NOT NULL; completed_at NOT NULL.
--   superseded (reached only from a never-started pending row -- see
--   `maybe_enqueue_triage_escalation_in_tx`, which only supersedes the
--   item's still-pending row when its evidence fingerprint goes stale
--   before an executor ever claims it):
--                            started_at NULL; completed_at NOT NULL.
CREATE TABLE IF NOT EXISTS task_board_triage_escalations (
    escalation_id           TEXT PRIMARY KEY CHECK (length(escalation_id) > 0),
    item_id                 TEXT NOT NULL,
    evidence_fingerprint    TEXT NOT NULL
                                CHECK (
                                    substr(evidence_fingerprint, 1, 7) = 'sha256:'
                                    AND length(evidence_fingerprint) = 71
                                ),
    status                  TEXT NOT NULL
                                CHECK (
                                    status IN (
                                        'pending', 'running', 'succeeded', 'failed',
                                        'timed_out', 'superseded', 'rejected'
                                    )
                                ),
    attempt                 INTEGER NOT NULL DEFAULT 1 CHECK (attempt > 0),
    requested_at            TEXT NOT NULL CHECK (requested_at GLOB '????-??-??T??:??:??Z'),
    started_at              TEXT CHECK (started_at IS NULL OR started_at GLOB '????-??-??T??:??:??Z'),
    completed_at            TEXT CHECK (completed_at IS NULL OR completed_at GLOB '????-??-??T??:??:??Z'),
    verdict_token           TEXT CHECK (verdict_token IS NULL OR length(verdict_token) >= 16),
    managed_run_id          TEXT CHECK (managed_run_id IS NULL OR length(managed_run_id) > 0),
    failure_reason          TEXT CHECK (failure_reason IS NULL OR length(CAST(failure_reason AS BLOB)) <= 1024),
    CHECK (
        (status = 'pending'
            AND started_at IS NULL AND verdict_token IS NULL AND managed_run_id IS NULL
            AND completed_at IS NULL)
        OR (status = 'running'
            AND started_at IS NOT NULL AND verdict_token IS NOT NULL AND managed_run_id IS NOT NULL
            AND completed_at IS NULL)
        OR (status IN ('succeeded', 'failed', 'timed_out', 'rejected')
            AND started_at IS NOT NULL AND completed_at IS NOT NULL)
        OR (status = 'superseded'
            AND started_at IS NULL AND verdict_token IS NULL AND managed_run_id IS NULL
            AND completed_at IS NOT NULL)
    ),
    FOREIGN KEY (item_id) REFERENCES task_board_items(item_id) ON DELETE RESTRICT
) WITHOUT ROWID;

CREATE UNIQUE INDEX IF NOT EXISTS task_board_triage_escalations_active
    ON task_board_triage_escalations(item_id)
    WHERE status IN ('pending', 'running');

CREATE INDEX IF NOT EXISTS task_board_triage_escalations_drain_order
    ON task_board_triage_escalations(status, requested_at);

UPDATE schema_meta SET value = '49' WHERE key = 'version';
