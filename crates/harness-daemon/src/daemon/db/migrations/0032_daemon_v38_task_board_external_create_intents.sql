CREATE TABLE IF NOT EXISTS task_board_external_create_intents (
    intent_id             TEXT PRIMARY KEY CHECK (length(intent_id) > 0),
    item_id               TEXT NOT NULL
                              CHECK (length(item_id) > 0)
                              REFERENCES task_board_items(item_id) ON DELETE RESTRICT,
    item_revision         INTEGER NOT NULL CHECK (item_revision > 0),
    provider              TEXT NOT NULL,
    scope_id              TEXT NOT NULL CHECK (length(scope_id) > 0),
    create_key            TEXT NOT NULL CHECK (length(create_key) > 0),
    state                 TEXT NOT NULL
                              CHECK (state IN ('in_flight', 'created', 'attached')),
    create_snapshot_json  TEXT NOT NULL
                               CHECK (
                                   json_valid(create_snapshot_json)
                                   AND json_type(create_snapshot_json) = 'object'
                               ),
    changed_fields_json   TEXT NOT NULL
                               CHECK (
                                   json_valid(changed_fields_json)
                                   AND json_type(changed_fields_json) = 'array'
                               ),
    outcome_json          TEXT,
    external_ref_json     TEXT,
    created_at            TEXT NOT NULL
                              CHECK (created_at GLOB '????-??-??T??:??:??Z'),
    outcome_recorded_at   TEXT
                              CHECK (
                                  outcome_recorded_at IS NULL
                                  OR outcome_recorded_at GLOB '????-??-??T??:??:??Z'
                              ),
    attached_at           TEXT
                              CHECK (
                                  attached_at IS NULL
                                  OR attached_at GLOB '????-??-??T??:??:??Z'
                              ),
    attached_item_revision INTEGER,
    follow_up_completed_at TEXT
                              CHECK (
                                  follow_up_completed_at IS NULL
                                  OR follow_up_completed_at GLOB '????-??-??T??:??:??Z'
                              ),
    follow_up_audit_event_id TEXT
                                 CHECK (
                                     follow_up_audit_event_id IS NULL
                                     OR length(follow_up_audit_event_id) > 0
                                 ),
    updated_at            TEXT NOT NULL
                              CHECK (updated_at GLOB '????-??-??T??:??:??Z'),
    CHECK (
        (
            state = 'in_flight'
            AND outcome_json IS NULL
            AND external_ref_json IS NULL
            AND outcome_recorded_at IS NULL
            AND attached_at IS NULL
            AND attached_item_revision IS NULL
            AND follow_up_completed_at IS NULL
            AND follow_up_audit_event_id IS NULL
            AND updated_at = created_at
        )
        OR
        (
            state = 'created'
            AND outcome_json IS NOT NULL
            AND external_ref_json IS NOT NULL
            AND json_valid(outcome_json)
            AND json_valid(external_ref_json)
            AND outcome_recorded_at IS NOT NULL
            AND outcome_recorded_at > created_at
            AND attached_at IS NULL
            AND attached_item_revision IS NULL
            AND follow_up_completed_at IS NULL
            AND follow_up_audit_event_id IS NULL
            AND updated_at = outcome_recorded_at
        )
        OR
        (
            state = 'attached'
            AND outcome_json IS NOT NULL
            AND external_ref_json IS NOT NULL
            AND json_valid(outcome_json)
            AND json_valid(external_ref_json)
            AND outcome_recorded_at IS NOT NULL
            AND outcome_recorded_at > created_at
            AND attached_at IS NOT NULL
            AND attached_at > outcome_recorded_at
            AND attached_item_revision IS NOT NULL
            AND attached_item_revision >= item_revision
            AND (
                (
                    follow_up_completed_at IS NULL
                    AND follow_up_audit_event_id IS NULL
                )
                OR
                (
                    follow_up_completed_at IS NOT NULL
                    AND follow_up_audit_event_id IS NOT NULL
                    AND follow_up_completed_at > attached_at
                )
            )
            AND updated_at = attached_at
        )
    )
) WITHOUT ROWID;

CREATE UNIQUE INDEX IF NOT EXISTS idx_task_board_external_create_intents_create_key
    ON task_board_external_create_intents(provider, create_key);

CREATE UNIQUE INDEX IF NOT EXISTS idx_task_board_external_create_intents_one_active
    ON task_board_external_create_intents(item_id, provider)
    WHERE state IN ('in_flight', 'created');

CREATE INDEX IF NOT EXISTS idx_task_board_external_create_intents_active_scope_state
    ON task_board_external_create_intents(
        provider, scope_id, state, updated_at, intent_id
    )
    WHERE state IN ('in_flight', 'created');

CREATE INDEX IF NOT EXISTS idx_task_board_external_create_intents_created_recovery
    ON task_board_external_create_intents(outcome_recorded_at, intent_id)
    WHERE state = 'created';

CREATE INDEX IF NOT EXISTS idx_task_board_external_create_intents_pending_follow_up
    ON task_board_external_create_intents(
        provider, scope_id, attached_at, intent_id
    )
    WHERE state = 'attached'
      AND follow_up_completed_at IS NULL
      AND follow_up_audit_event_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_task_board_external_create_intents_item_history
    ON task_board_external_create_intents(item_id, provider, updated_at DESC, intent_id);

UPDATE schema_meta SET value = '38' WHERE key = 'version';
