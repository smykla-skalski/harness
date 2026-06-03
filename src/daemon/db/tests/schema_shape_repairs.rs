use tempfile::tempdir;

use super::*;

#[tokio::test]
async fn async_connect_repairs_current_schema_missing_policy_columns() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    drop(sync_db);

    let conn = Connection::open(&db_path).expect("open sqlite");
    conn.execute_batch(
        "DROP TABLE policy_group_nodes;
         DROP TABLE policy_groups;
         DROP TABLE policy_edges;
         DROP TABLE policy_nodes;
         DROP TABLE policy_canvases;
         DROP TABLE policy_workspace;
         CREATE TABLE policy_workspace (
             singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
             active_canvas_id TEXT NOT NULL,
             workspace_schema_version INTEGER NOT NULL,
             updated_at TEXT NOT NULL,
             review_text_paste_dry_run_canvas_deleted INTEGER NOT NULL DEFAULT 0
         ) WITHOUT ROWID;
         CREATE TABLE policy_canvases (
             canvas_id TEXT PRIMARY KEY,
             position INTEGER NOT NULL DEFAULT 0,
             title TEXT NOT NULL,
             graph_schema_version INTEGER NOT NULL,
             revision INTEGER NOT NULL,
             mode TEXT NOT NULL,
             policy_trace_ids_json TEXT NOT NULL DEFAULT '[]',
             latest_simulation_json TEXT,
             created_at TEXT NOT NULL,
             updated_at TEXT NOT NULL,
             is_review_text_paste_dry_run_canvas INTEGER NOT NULL DEFAULT 0
         ) WITHOUT ROWID;
         CREATE TABLE policy_nodes (
             canvas_id TEXT NOT NULL REFERENCES policy_canvases(canvas_id) ON DELETE CASCADE,
             node_id TEXT NOT NULL,
             position INTEGER NOT NULL DEFAULT 0,
             label TEXT NOT NULL,
             kind_tag TEXT NOT NULL,
             kind_config_json TEXT NOT NULL,
             automation_json TEXT,
             input_ports_json TEXT NOT NULL DEFAULT '[]',
             output_ports_json TEXT NOT NULL DEFAULT '[]',
             group_id TEXT,
             layout_x INTEGER,
             layout_y INTEGER,
             PRIMARY KEY (canvas_id, node_id)
         ) WITHOUT ROWID;
         CREATE TABLE policy_edges (
             canvas_id TEXT NOT NULL REFERENCES policy_canvases(canvas_id) ON DELETE CASCADE,
             edge_id TEXT NOT NULL,
             position INTEGER NOT NULL DEFAULT 0,
             from_node TEXT NOT NULL,
             from_port TEXT NOT NULL,
             to_node TEXT NOT NULL,
             to_port TEXT NOT NULL,
             label TEXT,
             condition_tag TEXT NOT NULL,
             condition_config_json TEXT NOT NULL,
             PRIMARY KEY (canvas_id, edge_id)
         ) WITHOUT ROWID;
         CREATE TABLE policy_groups (
             canvas_id TEXT NOT NULL REFERENCES policy_canvases(canvas_id) ON DELETE CASCADE,
             group_id TEXT NOT NULL,
             position INTEGER NOT NULL DEFAULT 0,
             label TEXT NOT NULL,
             color TEXT,
             frame_x INTEGER NOT NULL DEFAULT 0,
             frame_y INTEGER NOT NULL DEFAULT 0,
             frame_width INTEGER NOT NULL DEFAULT 0,
             frame_height INTEGER NOT NULL DEFAULT 0,
             PRIMARY KEY (canvas_id, group_id)
         ) WITHOUT ROWID;
         CREATE TABLE policy_group_nodes (
             canvas_id TEXT NOT NULL REFERENCES policy_canvases(canvas_id) ON DELETE CASCADE,
             group_id TEXT NOT NULL,
             node_id TEXT NOT NULL,
             position INTEGER NOT NULL DEFAULT 0,
             PRIMARY KEY (canvas_id, group_id, node_id)
         ) WITHOUT ROWID;
         INSERT INTO policy_workspace (
             singleton, active_canvas_id, workspace_schema_version, updated_at
         ) VALUES (1, 'default', 1, '2026-06-02T12:00:00Z');
         INSERT INTO policy_canvases (
             canvas_id, position, title, graph_schema_version, revision, mode,
             policy_trace_ids_json, created_at, updated_at,
             is_review_text_paste_dry_run_canvas
         ) VALUES
             ('default', 0, 'Default', 2, 66, 'draft', '[]',
              '2026-06-02T12:00:00Z', '2026-06-02T12:00:00Z', 0),
             ('pasted-pr-approvals', 1, 'Pasted PR approvals', 2, 7, 'draft',
              '[\"review-text-paste-dry-run-canvas-v1\"]',
              '2026-06-02T12:00:00Z', '2026-06-02T12:00:00Z', 1),
             ('pasted-pr-approvals-dry-run', 2, 'Pasted PR approvals (dry run)',
              2, 1, 'enforced', '[]',
              '2026-06-02T12:00:00Z', '2026-06-02T12:00:00Z', 0);
         UPDATE schema_meta SET value = '20' WHERE key = 'version';",
    )
    .expect("seed current-stamped policy schema missing newer columns");
    drop(conn);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db");
    let workspace = async_db
        .load_policy_workspace()
        .await
        .expect("load repaired policy workspace")
        .expect("policy workspace present");
    let titles = workspace
        .canvases
        .iter()
        .map(|canvas| canvas.title.as_str())
        .collect::<Vec<_>>();

    assert_eq!(
        titles,
        vec![
            "Default",
            "Pasted PR approvals",
            "Pasted PR approvals (dry run)"
        ]
    );
}
