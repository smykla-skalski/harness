-- Policy-graph storage (schema v14). Stores policy canvases in normalized rows
-- so the database is the single source of truth. Graph structure is columnar;
-- irreducible per-variant payloads (node kind, edge condition, automation) ride
-- as JSON on their row.

CREATE TABLE IF NOT EXISTS policy_workspace (
    singleton                INTEGER PRIMARY KEY CHECK (singleton = 1),
    active_canvas_id         TEXT NOT NULL,
    workspace_schema_version INTEGER NOT NULL,
    updated_at               TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS policy_canvases (
    canvas_id              TEXT PRIMARY KEY,
    position               INTEGER NOT NULL DEFAULT 0,
    title                  TEXT NOT NULL,
    graph_schema_version   INTEGER NOT NULL,
    revision               INTEGER NOT NULL,
    mode                   TEXT NOT NULL,
    policy_trace_ids_json  TEXT NOT NULL DEFAULT '[]',
    latest_simulation_json TEXT,
    created_at             TEXT NOT NULL,
    updated_at             TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS policy_nodes (
    canvas_id         TEXT NOT NULL REFERENCES policy_canvases(canvas_id) ON DELETE CASCADE,
    node_id           TEXT NOT NULL,
    position          INTEGER NOT NULL DEFAULT 0,
    label             TEXT NOT NULL,
    kind_tag          TEXT NOT NULL,
    kind_config_json  TEXT NOT NULL,
    automation_json   TEXT,
    input_ports_json  TEXT NOT NULL DEFAULT '[]',
    output_ports_json TEXT NOT NULL DEFAULT '[]',
    group_id          TEXT,
    layout_x          INTEGER,
    layout_y          INTEGER,
    PRIMARY KEY (canvas_id, node_id)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_policy_nodes_canvas ON policy_nodes(canvas_id, position);

CREATE TABLE IF NOT EXISTS policy_edges (
    canvas_id             TEXT NOT NULL REFERENCES policy_canvases(canvas_id) ON DELETE CASCADE,
    edge_id               TEXT NOT NULL,
    position              INTEGER NOT NULL DEFAULT 0,
    from_node             TEXT NOT NULL,
    from_port             TEXT NOT NULL,
    to_node               TEXT NOT NULL,
    to_port               TEXT NOT NULL,
    label                 TEXT,
    condition_tag         TEXT NOT NULL,
    condition_config_json TEXT NOT NULL,
    PRIMARY KEY (canvas_id, edge_id)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_policy_edges_canvas ON policy_edges(canvas_id, position);

CREATE TABLE IF NOT EXISTS policy_groups (
    canvas_id    TEXT NOT NULL REFERENCES policy_canvases(canvas_id) ON DELETE CASCADE,
    group_id     TEXT NOT NULL,
    position     INTEGER NOT NULL DEFAULT 0,
    label        TEXT NOT NULL,
    color        TEXT,
    frame_x      INTEGER NOT NULL DEFAULT 0,
    frame_y      INTEGER NOT NULL DEFAULT 0,
    frame_width  INTEGER NOT NULL DEFAULT 0,
    frame_height INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (canvas_id, group_id)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_policy_groups_canvas ON policy_groups(canvas_id, position);

CREATE TABLE IF NOT EXISTS policy_group_nodes (
    canvas_id TEXT NOT NULL REFERENCES policy_canvases(canvas_id) ON DELETE CASCADE,
    group_id  TEXT NOT NULL,
    node_id   TEXT NOT NULL,
    position  INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (canvas_id, group_id, node_id)
) WITHOUT ROWID;

UPDATE schema_meta SET value = '14' WHERE key = 'version';
