use tempfile::tempdir;

use super::*;

#[tokio::test]
async fn async_connect_repairs_current_schema_missing_external_create_intents() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    sync_db
        .connection()
        .execute("DROP TABLE task_board_external_create_intents", [])
        .expect("drop external create intents");
    drop(sync_db);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("repair external create intents");
    let exists: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sqlite_master
         WHERE type = 'table' AND name = 'task_board_external_create_intents'",
    )
    .fetch_one(async_db.pool())
    .await
    .expect("inspect repaired table");

    assert_eq!(exists, 1);
    assert_eq!(
        async_db.schema_version().await.expect("schema version"),
        SCHEMA_VERSION
    );
}

#[tokio::test]
async fn async_connect_repairs_current_schema_missing_external_create_index() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    sync_db
        .connection()
        .execute(
            "DROP INDEX idx_task_board_external_create_intents_create_key",
            [],
        )
        .expect("drop external create key index");
    drop(sync_db);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("repair external create key index");
    let exists: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sqlite_master
         WHERE type = 'index'
           AND name = 'idx_task_board_external_create_intents_create_key'",
    )
    .fetch_one(async_db.pool())
    .await
    .expect("inspect repaired index");

    assert_eq!(exists, 1);
}

#[tokio::test]
async fn async_connect_refuses_nonunique_external_create_index_with_expected_name() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    sync_db
        .connection()
        .execute_batch(
            "DROP INDEX idx_task_board_external_create_intents_create_key;
             CREATE INDEX idx_task_board_external_create_intents_create_key
             ON task_board_external_create_intents(provider, create_key);",
        )
        .expect("replace unique create-key index");
    drop(sync_db);

    let error = AsyncDaemonDb::connect(&db_path)
        .await
        .expect_err("nonunique create-key index must fail closed");

    assert!(error.to_string().contains("create_key"));
    let conn = Connection::open(&db_path).expect("reopen incompatible database");
    let unique: i64 = conn
        .query_row(
            "SELECT \"unique\"
             FROM pragma_index_list('task_board_external_create_intents')
             WHERE name = 'idx_task_board_external_create_intents_create_key'",
            [],
            |row| row.get(0),
        )
        .expect("inspect preserved nonunique index");
    assert_eq!(unique, 0);
}

#[tokio::test]
async fn async_connect_inspects_malformed_indexes_even_when_another_index_is_missing() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    sync_db
        .connection()
        .execute_batch(
            "DROP INDEX idx_task_board_external_create_intents_create_key;
             DROP INDEX idx_task_board_external_create_intents_one_active;
             CREATE INDEX idx_task_board_external_create_intents_one_active
             ON task_board_external_create_intents(provider, item_id)
             WHERE state = 'created';",
        )
        .expect("seed missing and malformed indexes");
    drop(sync_db);

    let error = AsyncDaemonDb::connect(&db_path)
        .await
        .expect_err("malformed present index must fail closed");

    assert!(error.to_string().contains("one_active"));
    let conn = Connection::open(&db_path).expect("reopen incompatible database");
    let missing: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'index'
               AND name = 'idx_task_board_external_create_intents_create_key'",
            [],
            |row| row.get(0),
        )
        .expect("inspect missing index");
    assert_eq!(missing, 0, "failed validation must not mask repair");
}

#[tokio::test]
async fn async_connect_refuses_incompatible_external_create_intent_shape() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    sync_db
        .connection()
        .execute_batch(
            "DROP TABLE task_board_external_create_intents;
             CREATE TABLE task_board_external_create_intents (
                 intent_id TEXT PRIMARY KEY,
                 sentinel TEXT NOT NULL
             ) WITHOUT ROWID;
             INSERT INTO task_board_external_create_intents (intent_id, sentinel)
             VALUES ('sentinel-intent', 'preserve-me');",
        )
        .expect("seed incompatible external create intent table");
    drop(sync_db);

    let error = AsyncDaemonDb::connect(&db_path)
        .await
        .expect_err("incompatible intent shape must fail closed");
    assert!(error.to_string().contains("incompatible"));

    let conn = Connection::open(&db_path).expect("reopen incompatible database");
    let sentinel: String = conn
        .query_row(
            "SELECT sentinel FROM task_board_external_create_intents
             WHERE intent_id = 'sentinel-intent'",
            [],
            |row| row.get(0),
        )
        .expect("read preserved sentinel");
    assert_eq!(sentinel, "preserve-me");
}

#[tokio::test]
async fn async_connect_refuses_external_create_table_with_weakened_state_checks() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    let migration =
        include_str!("../migrations/0032_daemon_v38_task_board_external_create_intents.sql");
    let weakened = migration.replacen(
        "AND attached_item_revision >= item_revision",
        "AND attached_item_revision IS NOT NULL",
        1,
    );
    assert_ne!(weakened, migration);
    sync_db
        .connection()
        .execute_batch("DROP TABLE task_board_external_create_intents")
        .expect("drop constrained external create table");
    sync_db
        .connection()
        .execute_batch(&weakened)
        .expect("create weakened external create table");
    drop(sync_db);

    let error = AsyncDaemonDb::connect(&db_path)
        .await
        .expect_err("weakened state matrix must fail closed");

    assert!(
        error
            .to_string()
            .contains("incompatible task_board_external_create_intents schema")
    );
}

#[tokio::test]
async fn async_connect_refuses_each_omitted_external_create_constraint() {
    let migration =
        include_str!("../migrations/0032_daemon_v38_task_board_external_create_intents.sql");
    for (case, required, weakened) in [
        ("intent id", "CHECK (length(intent_id) > 0)", "CHECK (1)"),
        ("item id", "CHECK (length(item_id) > 0)", "CHECK (1)"),
        ("item revision", "CHECK (item_revision > 0)", "CHECK (1)"),
        ("scope", "CHECK (length(scope_id) > 0)", "CHECK (1)"),
        ("create key", "CHECK (length(create_key) > 0)", "CHECK (1)"),
        (
            "snapshot JSON",
            "json_valid(create_snapshot_json)",
            "json_type(create_snapshot_json) IS NOT NULL",
        ),
        (
            "changed fields JSON",
            "json_valid(changed_fields_json)",
            "json_type(changed_fields_json) IS NOT NULL",
        ),
        (
            "created timestamp",
            "created_at GLOB '????-??-??T??:??:??Z'",
            "created_at IS NOT NULL",
        ),
        (
            "in-flight recorded timestamp",
            "AND outcome_recorded_at IS NULL",
            "AND outcome_recorded_at IS outcome_recorded_at",
        ),
        (
            "created evidence JSON",
            "AND json_valid(outcome_json)",
            "AND outcome_json IS outcome_json",
        ),
        (
            "created timestamp order",
            "AND outcome_recorded_at > created_at",
            "AND outcome_recorded_at >= created_at",
        ),
        (
            "created attachment null",
            "AND attached_item_revision IS NULL\n            AND updated_at = outcome_recorded_at",
            "AND attached_item_revision IS attached_item_revision\n            AND updated_at = outcome_recorded_at",
        ),
        (
            "attached timestamp",
            "AND attached_at IS NOT NULL",
            "AND attached_at IS attached_at",
        ),
        (
            "attached timestamp order",
            "AND attached_at > outcome_recorded_at",
            "AND attached_at >= outcome_recorded_at",
        ),
        (
            "attached revision",
            "AND attached_item_revision IS NOT NULL",
            "AND attached_item_revision IS attached_item_revision",
        ),
    ] {
        let mutated = migration.replacen(required, weakened, 1);
        assert_ne!(mutated, migration, "missing fixture fragment for {case}");
        assert_external_create_shape_rejected(case, &mutated).await;
    }
}

#[tokio::test]
async fn async_connect_refuses_external_create_column_shape_drift() {
    let migration =
        include_str!("../migrations/0032_daemon_v38_task_board_external_create_intents.sql");
    let wrong_type = migration.replacen(
        "provider              TEXT NOT NULL",
        "provider              BLOB NOT NULL",
        1,
    );
    assert_external_create_shape_rejected("wrong type", &wrong_type).await;
    let nullable = migration.replacen(
        "scope_id              TEXT NOT NULL",
        "scope_id              TEXT",
        1,
    );
    assert_external_create_shape_rejected("nullable column", &nullable).await;
    let extra = migration.replacen(
        "updated_at            TEXT NOT NULL",
        "extra_column          TEXT,\n    updated_at            TEXT NOT NULL",
        1,
    );
    assert_external_create_shape_rejected("extra column", &extra).await;
    let wrong_primary_key = migration
        .replacen(
            "intent_id             TEXT PRIMARY KEY",
            "intent_id             TEXT NOT NULL UNIQUE",
            1,
        )
        .replacen(
            "item_id               TEXT NOT NULL",
            "item_id               TEXT PRIMARY KEY",
            1,
        );
    assert_external_create_shape_rejected("wrong primary key", &wrong_primary_key).await;
}

async fn assert_external_create_shape_rejected(case: &str, migration: &str) {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    sync_db
        .connection()
        .execute_batch("DROP TABLE task_board_external_create_intents")
        .expect("drop constrained external create table");
    sync_db
        .connection()
        .execute_batch(migration)
        .unwrap_or_else(|error| panic!("create {case} fixture: {error}"));
    drop(sync_db);

    let error = AsyncDaemonDb::connect(&db_path)
        .await
        .expect_err("weakened external create shape must fail closed");

    assert!(
        error
            .to_string()
            .contains("incompatible task_board_external_create_intents schema"),
        "case {case}: {error}"
    );
}

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
