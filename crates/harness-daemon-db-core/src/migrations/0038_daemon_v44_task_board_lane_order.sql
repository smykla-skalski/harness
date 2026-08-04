ALTER TABLE task_board_items ADD COLUMN lane_position INTEGER
    CONSTRAINT task_board_items_lane_position_range
    CHECK (lane_position BETWEEN 0 AND 4294967295);
ALTER TABLE task_board_items ADD COLUMN lane_origin TEXT
    CONSTRAINT task_board_items_lane_origin_values
    CHECK (lane_origin IN ('manual', 'automatic') OR lane_origin IS NULL);
ALTER TABLE task_board_items ADD COLUMN lane_actor TEXT;
ALTER TABLE task_board_items ADD COLUMN lane_producer TEXT;
ALTER TABLE task_board_items ADD COLUMN lane_set_at TEXT;

CREATE UNIQUE INDEX task_board_items_live_lane_position
    ON task_board_items(status, lane_position)
    WHERE deleted_at IS NULL AND lane_position IS NOT NULL;
CREATE INDEX task_board_items_live_lane_order
    ON task_board_items(status, lane_position, priority DESC, created_at, item_id)
    WHERE deleted_at IS NULL;

CREATE TRIGGER task_board_items_lane_coherence_insert
BEFORE INSERT ON task_board_items
WHEN (
    (NEW.lane_position IS NULL AND NEW.lane_origin IS NULL AND NEW.lane_actor IS NULL
        AND NEW.lane_producer IS NULL AND NEW.lane_set_at IS NULL)
    OR
    (NEW.lane_position IS NOT NULL AND NEW.lane_origin = 'manual'
        AND COALESCE(trim(NEW.lane_actor), '') <> '' AND NEW.lane_producer IS NULL
        AND length(NEW.lane_actor) <= 256 AND COALESCE(trim(NEW.lane_set_at), '') <> ''
        AND length(NEW.lane_set_at) <= 128)
    OR
    (NEW.lane_position IS NOT NULL AND NEW.lane_origin = 'automatic'
        AND NEW.lane_actor IS NULL AND COALESCE(trim(NEW.lane_producer), '') <> ''
        AND length(NEW.lane_producer) <= 256 AND COALESCE(trim(NEW.lane_set_at), '') <> ''
        AND length(NEW.lane_set_at) <= 128)
) IS NOT TRUE
BEGIN
    SELECT RAISE(ABORT, 'task board lane placement provenance is incoherent');
END;

CREATE TRIGGER task_board_items_lane_coherence_update
BEFORE UPDATE OF lane_position, lane_origin, lane_actor, lane_producer, lane_set_at
ON task_board_items
WHEN (
    (NEW.lane_position IS NULL AND NEW.lane_origin IS NULL AND NEW.lane_actor IS NULL
        AND NEW.lane_producer IS NULL AND NEW.lane_set_at IS NULL)
    OR
    (NEW.lane_position IS NOT NULL AND NEW.lane_origin = 'manual'
        AND COALESCE(trim(NEW.lane_actor), '') <> '' AND NEW.lane_producer IS NULL
        AND length(NEW.lane_actor) <= 256 AND COALESCE(trim(NEW.lane_set_at), '') <> ''
        AND length(NEW.lane_set_at) <= 128)
    OR
    (NEW.lane_position IS NOT NULL AND NEW.lane_origin = 'automatic'
        AND NEW.lane_actor IS NULL AND COALESCE(trim(NEW.lane_producer), '') <> ''
        AND length(NEW.lane_producer) <= 256 AND COALESCE(trim(NEW.lane_set_at), '') <> ''
        AND length(NEW.lane_set_at) <= 128)
) IS NOT TRUE
BEGIN
    SELECT RAISE(ABORT, 'task board lane placement provenance is incoherent');
END;

UPDATE schema_meta SET value = '44' WHERE key = 'version';
