ALTER TABLE task_board_items ADD COLUMN triage_override_verdict TEXT
    CONSTRAINT task_board_items_triage_override_verdict_values
    CHECK (triage_override_verdict IS NULL OR triage_override_verdict IN ('todo', 'undecided'));

ALTER TABLE task_board_items ADD COLUMN triage_override_actor TEXT
    CONSTRAINT task_board_items_triage_override_actor_coherence
    CHECK (
        (triage_override_verdict IS NULL AND triage_override_actor IS NULL)
        OR (
            triage_override_verdict IS NOT NULL
            AND triage_override_actor IS NOT NULL
            AND length(trim(
                triage_override_actor,
                ' ' || char(9) || char(10) || char(11) || char(12) || char(13)
            )) > 0
            AND length(CAST(triage_override_actor AS BLOB)) <= 256
        )
    );

ALTER TABLE task_board_items ADD COLUMN triage_override_reason TEXT
    CONSTRAINT task_board_items_triage_override_reason_coherence
    CHECK (
        triage_override_reason IS NULL
        OR (
            triage_override_verdict IS NOT NULL
            AND length(trim(
                triage_override_reason,
                ' ' || char(9) || char(10) || char(11) || char(12) || char(13)
            )) > 0
            AND length(CAST(triage_override_reason AS BLOB)) <= 256
        )
    );

ALTER TABLE task_board_items ADD COLUMN triage_override_set_at TEXT
    CONSTRAINT task_board_items_triage_override_set_at_coherence
    CHECK (
        (triage_override_verdict IS NULL AND triage_override_set_at IS NULL)
        OR (
            triage_override_verdict IS NOT NULL
            AND triage_override_set_at IS NOT NULL
            AND triage_override_set_at GLOB '????-??-??T??:??:??Z'
        )
    );

UPDATE schema_meta SET value = '47' WHERE key = 'version';
