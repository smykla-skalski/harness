ALTER TABLE task_board_items
    ADD COLUMN estimated_tokens INTEGER
        CHECK (
            estimated_tokens IS NULL
            OR (
                typeof(estimated_tokens) = 'integer'
                AND estimated_tokens BETWEEN 1 AND 9223372036854775807
            )
        );

ALTER TABLE task_board_items
    ADD COLUMN estimated_cost_microusd INTEGER
        CHECK (
            estimated_cost_microusd IS NULL
            OR (
                typeof(estimated_cost_microusd) = 'integer'
                AND estimated_cost_microusd BETWEEN 1 AND 9223372036854775807
            )
        );

CREATE UNIQUE INDEX IF NOT EXISTS task_board_dispatch_intents_admission_identity
    ON task_board_dispatch_intents(intent_id, item_id);

CREATE TABLE IF NOT EXISTS task_board_dispatch_admission_decisions (
    decision_id          TEXT PRIMARY KEY CHECK (length(decision_id) > 0),
    intent_id            TEXT,
    generation           INTEGER NOT NULL
                             CHECK (typeof(generation) = 'integer' AND generation > 0),
    item_id              TEXT NOT NULL,
    item_revision        INTEGER NOT NULL
                             CHECK (typeof(item_revision) = 'integer' AND item_revision > 0),
    settings_revision    INTEGER NOT NULL
                             CHECK (typeof(settings_revision) = 'integer' AND settings_revision > 0),
    decision             TEXT NOT NULL
                             CHECK (decision IN ('allowed', 'deferred', 'rejected')),
    policy_json          TEXT NOT NULL
                             CHECK (
                                 json_valid(policy_json)
                                 AND json_type(policy_json) = 'object'
                             ),
    context_json         TEXT NOT NULL
                             CHECK (
                                 json_valid(context_json)
                                 AND json_type(context_json) = 'object'
                             ),
    requirements_json    TEXT NOT NULL
                             CHECK (
                                 json_valid(requirements_json)
                                 AND json_type(requirements_json) = 'array'
                             ),
    blockers_json        TEXT NOT NULL
                             CHECK (
                                 json_valid(blockers_json)
                                 AND json_type(blockers_json) = 'array'
                             ),
    launch_profile       TEXT
                             CHECK (
                                 launch_profile IS NULL
                                 OR launch_profile IN ('read_only', 'workspace_write')
                             ),
    evaluated_at         TEXT NOT NULL
                             CHECK (evaluated_at GLOB '????-??-??T??:??:??Z'),
    next_available_at    TEXT
                             CHECK (
                                 next_available_at IS NULL
                                 OR next_available_at GLOB '????-??-??T??:??:??Z'
                             ),
    is_current           INTEGER NOT NULL DEFAULT 1
                             CHECK (is_current IN (0, 1)),
    superseded_at        TEXT
                             CHECK (
                                 superseded_at IS NULL
                                 OR superseded_at GLOB '????-??-??T??:??:??Z'
                             ),
    created_at           TEXT NOT NULL
                             CHECK (created_at GLOB '????-??-??T??:??:??Z'),
    CHECK (
        (decision = 'allowed' AND intent_id IS NOT NULL)
        OR (decision IN ('deferred', 'rejected') AND intent_id IS NULL)
    ),
    CHECK (
        (decision = 'deferred' AND next_available_at IS NOT NULL)
        OR (decision != 'deferred' AND next_available_at IS NULL)
    ),
    CHECK (
        (is_current = 1 AND superseded_at IS NULL)
        OR (
            is_current = 0
            AND superseded_at IS NOT NULL
            AND superseded_at >= created_at
        )
    ),
    UNIQUE(intent_id, generation),
    UNIQUE(decision_id, intent_id, generation, item_id, decision),
    FOREIGN KEY (intent_id, item_id)
        REFERENCES task_board_dispatch_intents(intent_id, item_id)
        ON DELETE RESTRICT,
    FOREIGN KEY (item_id)
        REFERENCES task_board_items(item_id)
        ON DELETE RESTRICT
) WITHOUT ROWID;

CREATE UNIQUE INDEX IF NOT EXISTS task_board_dispatch_admission_decisions_current_intent
    ON task_board_dispatch_admission_decisions(intent_id)
    WHERE intent_id IS NOT NULL AND is_current = 1;

CREATE UNIQUE INDEX IF NOT EXISTS task_board_dispatch_admission_decisions_current_item
    ON task_board_dispatch_admission_decisions(item_id)
    WHERE intent_id IS NULL AND is_current = 1;

CREATE INDEX IF NOT EXISTS task_board_dispatch_admission_decisions_item_history
    ON task_board_dispatch_admission_decisions(
        item_id, created_at DESC, generation DESC, decision_id
    );

CREATE TABLE IF NOT EXISTS task_board_dispatch_admission_ledger (
    ledger_id            TEXT PRIMARY KEY CHECK (length(ledger_id) > 0),
    decision_id          TEXT NOT NULL,
    decision             TEXT NOT NULL CHECK (decision = 'allowed'),
    intent_id            TEXT NOT NULL,
    generation           INTEGER NOT NULL
                             CHECK (typeof(generation) = 'integer' AND generation > 0),
    item_id              TEXT NOT NULL,
    canonical_key        TEXT NOT NULL CHECK (length(canonical_key) > 0),
    kind                 TEXT NOT NULL
                             CHECK (
                                 kind IN (
                                     'concurrency', 'rate', 'time_window',
                                     'token_budget', 'monetary_budget'
                                 )
                             ),
    scope                TEXT NOT NULL CHECK (length(scope) > 0),
    amount               INTEGER NOT NULL
                             CHECK (typeof(amount) = 'integer' AND amount >= 0),
    limit_value          INTEGER NOT NULL
                             CHECK (typeof(limit_value) = 'integer' AND limit_value > 0),
    window_started_at    TEXT
                             CHECK (
                                 window_started_at IS NULL
                                 OR window_started_at GLOB '????-??-??T??:??:??Z'
                             ),
    window_ends_at       TEXT
                             CHECK (
                                 window_ends_at IS NULL
                                 OR window_ends_at GLOB '????-??-??T??:??:??Z'
                             ),
    state                TEXT NOT NULL
                             CHECK (state IN ('reserved', 'committed', 'released')),
    managed_worker_id    TEXT
                             CHECK (
                                 managed_worker_id IS NULL
                                 OR length(managed_worker_id) > 0
                             ),
    expires_at           TEXT
                             CHECK (
                                 expires_at IS NULL
                                 OR expires_at GLOB '????-??-??T??:??:??Z'
                             ),
    reserved_at          TEXT NOT NULL
                             CHECK (reserved_at GLOB '????-??-??T??:??:??Z'),
    committed_at         TEXT
                             CHECK (
                                 committed_at IS NULL
                                 OR committed_at GLOB '????-??-??T??:??:??Z'
                             ),
    released_at          TEXT
                             CHECK (
                                 released_at IS NULL
                                 OR released_at GLOB '????-??-??T??:??:??Z'
                             ),
    CHECK (
        (
            kind = 'concurrency'
            AND amount = 1
            AND window_started_at IS NULL
            AND window_ends_at IS NULL
        )
        OR (
            kind = 'rate'
            AND amount = 1
            AND window_started_at IS NOT NULL
            AND window_ends_at > window_started_at
        )
        OR (
            kind = 'time_window'
            AND amount = 0
            AND window_started_at IS NOT NULL
            AND window_ends_at > window_started_at
        )
        OR (
            kind IN ('token_budget', 'monetary_budget')
            AND amount > 0
            AND window_started_at IS NOT NULL
            AND window_ends_at > window_started_at
        )
    ),
    CHECK (
        (
            state = 'reserved'
            AND managed_worker_id IS NULL
            AND expires_at IS NOT NULL
            AND committed_at IS NULL
            AND released_at IS NULL
        )
        OR (
            state = 'committed'
            AND managed_worker_id IS NOT NULL
            AND expires_at IS NULL
            AND committed_at IS NOT NULL
            AND released_at IS NULL
        )
        OR (
            state = 'released'
            AND expires_at IS NULL
            AND released_at IS NOT NULL
            AND (
                (
                    committed_at IS NULL
                    AND managed_worker_id IS NULL
                )
                OR (
                    kind = 'concurrency'
                    AND committed_at IS NOT NULL
                    AND managed_worker_id IS NOT NULL
                    AND released_at >= committed_at
                )
            )
        )
    ),
    UNIQUE(decision_id, canonical_key),
    FOREIGN KEY (decision_id, intent_id, generation, item_id, decision)
        REFERENCES task_board_dispatch_admission_decisions(
            decision_id, intent_id, generation, item_id, decision
        )
        ON DELETE RESTRICT
) WITHOUT ROWID;

CREATE UNIQUE INDEX IF NOT EXISTS task_board_dispatch_admission_ledger_current_requirement
    ON task_board_dispatch_admission_ledger(intent_id, canonical_key)
    WHERE state IN ('reserved', 'committed');

CREATE INDEX IF NOT EXISTS task_board_dispatch_admission_ledger_usage
    ON task_board_dispatch_admission_ledger(
        kind, scope, window_started_at, window_ends_at, state
    );

CREATE INDEX IF NOT EXISTS task_board_dispatch_admission_ledger_intent_generation
    ON task_board_dispatch_admission_ledger(
        intent_id, generation, state, canonical_key
    );

INSERT INTO task_board_orchestrator_settings (
    singleton, settings_json, revision, updated_at
) VALUES (
    1,
    '{"admission_policy":{"limits":[],"windows":[]}}',
    1,
    strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
)
ON CONFLICT(singleton) DO NOTHING;

UPDATE schema_meta SET value = '39' WHERE key = 'version';
