use rusqlite::Connection;

use super::CliError;

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    super::schema_repairs_admission::repair_and_stamp(conn)
}

#[cfg(test)]
mod tests {
    use super::run;
    use crate::daemon::db::DaemonDb;

    #[test]
    fn current_schema_contains_task_board_admission_storage() {
        let db = DaemonDb::open_in_memory().expect("open daemon db");

        assert_eq!(db.schema_version().expect("schema version"), "39");
        for column in ["estimated_tokens", "estimated_cost_microusd"] {
            let exists: i64 = db
                .connection()
                .query_row(
                    "SELECT COUNT(*) FROM pragma_table_xinfo('task_board_items')
                     WHERE name = ?1",
                    [column],
                    |row| row.get(0),
                )
                .expect("read task-board item column");
            assert_eq!(exists, 1, "missing task-board item column {column}");
        }
        for table in [
            "task_board_dispatch_admission_decisions",
            "task_board_dispatch_admission_ledger",
        ] {
            let exists: i64 = db
                .connection()
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master
                     WHERE type = 'table' AND name = ?1",
                    [table],
                    |row| row.get(0),
                )
                .expect("read task-board admission table");
            assert_eq!(exists, 1, "missing task-board admission table {table}");
        }
        let settings_json: String = db
            .connection()
            .query_row(
                "SELECT settings_json FROM task_board_orchestrator_settings
                 WHERE singleton = 1",
                [],
                |row| row.get(0),
            )
            .expect("read seeded orchestrator settings");
        assert_eq!(
            settings_json,
            r#"{"admission_policy":{"limits":[],"windows":[]}}"#
        );
    }

    #[test]
    fn migration_is_restart_safe_and_preserves_existing_settings() {
        let db = DaemonDb::open_in_memory().expect("open daemon db");
        db.connection()
            .execute_batch(
                "UPDATE task_board_orchestrator_settings
                     SET settings_json = '{\"enabled\":true}', revision = 7,
                         updated_at = '2026-07-17T10:00:00Z'
                   WHERE singleton = 1;
                 DROP TABLE task_board_dispatch_admission_ledger;
                 DROP TABLE task_board_dispatch_admission_decisions;
                 DROP INDEX task_board_dispatch_intents_admission_identity;
                 ALTER TABLE task_board_items DROP COLUMN estimated_cost_microusd;
                 UPDATE schema_meta SET value = '38' WHERE key = 'version';",
            )
            .expect("restore a partially migrated v38 shape");

        run(db.connection()).expect("repair partial v39 migration");
        run(db.connection()).expect("repeat v39 migration");

        assert_eq!(db.schema_version().expect("schema version"), "39");
        let (settings_json, revision): (String, i64) = db
            .connection()
            .query_row(
                "SELECT settings_json, revision
                 FROM task_board_orchestrator_settings WHERE singleton = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("read preserved settings");
        assert_eq!(settings_json, r#"{"enabled":true}"#);
        assert_eq!(revision, 7);
    }

    #[test]
    fn migration_refuses_weakened_admission_index() {
        let db = DaemonDb::open_in_memory().expect("open daemon db");
        db.connection()
            .execute_batch(
                "DROP INDEX task_board_dispatch_admission_ledger_current_requirement;
                 CREATE INDEX task_board_dispatch_admission_ledger_current_requirement
                     ON task_board_dispatch_admission_ledger(intent_id, canonical_key);",
            )
            .expect("weaken admission index");

        let error = run(db.connection()).expect_err("weakened index must fail closed");

        assert!(
            error
                .to_string()
                .contains("admission task_board_dispatch_admission_ledger_current_requirement"),
            "unexpected error: {error}"
        );
    }
}
