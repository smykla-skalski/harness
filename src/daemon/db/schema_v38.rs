use rusqlite::Connection;

use super::{CliError, db_error};

const EXTERNAL_CREATE_INTENTS_SQL: &str =
    include_str!("migrations/0032_daemon_v38_task_board_external_create_intents.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(EXTERNAL_CREATE_INTENTS_SQL)
        .map_err(|error| {
            db_error(format!(
                "migrate task-board external create intents: {error}"
            ))
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
    use crate::task_board::TaskBoardItem;
    use tempfile::tempdir;

    #[test]
    fn migration_creates_constrained_external_create_intent_storage() {
        let db = DaemonDb::open_in_memory().expect("open daemon db");
        db.connection()
            .execute_batch(
                "DROP TABLE task_board_external_create_intents;
                 UPDATE schema_meta SET value = '37' WHERE key = 'version';",
            )
            .expect("restore v37 shape");

        run(db.connection()).expect("run external create intent migration");
        run(db.connection()).expect("repeat external create intent migration");

        assert_eq!(db.schema_version().expect("schema version"), "38");
        let table_sql: String = db
            .connection()
            .query_row(
                "SELECT sql FROM sqlite_master
                 WHERE type = 'table' AND name = 'task_board_external_create_intents'",
                [],
                |row| row.get(0),
            )
            .expect("read intent table SQL");
        assert!(table_sql.contains("intent_id"));
        assert!(table_sql.contains("ON DELETE RESTRICT"));
        assert!(table_sql.contains("'in_flight', 'created', 'attached'"));
        for index in [
            "idx_task_board_external_create_intents_create_key",
            "idx_task_board_external_create_intents_one_active",
            "idx_task_board_external_create_intents_active_scope_state",
            "idx_task_board_external_create_intents_created_recovery",
            "idx_task_board_external_create_intents_pending_follow_up",
            "idx_task_board_external_create_intents_item_history",
        ] {
            let exists: i64 = db
                .connection()
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master
                     WHERE type = 'index' AND name = ?1",
                    [index],
                    |row| row.get(0),
                )
                .expect("read intent index");
            assert_eq!(exists, 1, "missing index {index}");
        }
    }

    #[tokio::test]
    async fn created_intent_requires_exact_outcome_and_reference_json() {
        let dir = tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
            .await
            .expect("database");
        db.create_task_board_item(TaskBoardItem::new(
            "task-schema-intent".into(),
            "Task".into(),
            String::new(),
            "2026-07-16T10:00:00Z".into(),
        ))
        .await
        .expect("create item");

        let error = sqlx::query(
            "INSERT INTO task_board_external_create_intents (
                intent_id, item_id, item_revision, provider, scope_id, create_key, state,
                create_snapshot_json, changed_fields_json, outcome_json, external_ref_json,
                created_at, outcome_recorded_at, attached_at, attached_item_revision, updated_at
             ) VALUES (
                'intent', 'task-schema-intent', 1, 'github', 'scope', 'create-key',
                'created', '{}', '[]', NULL, NULL, '2026-07-16T10:00:00Z',
                '2026-07-16T10:00:01Z', NULL, NULL, '2026-07-16T10:00:01Z'
             )",
        )
        .execute(db.pool())
        .await
        .expect_err("created state without evidence must fail");

        assert!(error.to_string().contains("CHECK constraint failed"));

        for (intent_id, snapshot, fields) in [
            ("snapshot-array", "[]", "[]"),
            ("fields-object", "{}", "{}"),
        ] {
            let error = sqlx::query(
                "INSERT INTO task_board_external_create_intents (
                    intent_id, item_id, item_revision, provider, scope_id, create_key, state,
                    create_snapshot_json, changed_fields_json, outcome_json, external_ref_json,
                    created_at, outcome_recorded_at, attached_at, attached_item_revision, updated_at
                 ) VALUES (
                    ?1, 'task-schema-intent', 1, 'github', 'scope', ?1, 'in_flight',
                    ?2, ?3, NULL, NULL, '2026-07-16T10:00:00Z',
                    NULL, NULL, NULL, '2026-07-16T10:00:00Z'
                 )",
            )
            .bind(intent_id)
            .bind(snapshot)
            .bind(fields)
            .execute(db.pool())
            .await
            .expect_err("incorrect JSON shape must fail");
            assert!(error.to_string().contains("CHECK constraint failed"));
        }
    }
}
