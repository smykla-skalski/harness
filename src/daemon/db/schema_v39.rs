use rusqlite::Connection;

use super::CliError;

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    super::schema_repairs_admission::repair_and_stamp(conn)
}

#[cfg(test)]
mod tests {
    use rusqlite::{Connection, Result as SqlResult, params};

    use super::run;
    use crate::daemon::db::DaemonDb;

    const NOW: &str = "2026-07-17T10:00:00Z";
    const LATER: &str = "2026-07-17T10:15:00Z";

    #[test]
    fn current_schema_contains_task_board_admission_storage() {
        let db = DaemonDb::open_in_memory().expect("open daemon db");

        assert_eq!(db.schema_version().expect("schema version"), "42");
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
        let compensation_column: (String, i64, Option<String>, i64) = db
            .connection()
            .query_row(
                "SELECT type, \"notnull\", dflt_value, hidden
                 FROM pragma_table_xinfo('task_board_dispatch_intents')
                 WHERE name = 'compensation_pending'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .expect("read dispatch compensation column");
        assert_eq!(
            compensation_column,
            ("INTEGER".to_string(), 1, Some("0".to_string()), 0)
        );
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
                 ALTER TABLE task_board_dispatch_intents DROP COLUMN compensation_pending;
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
        let compensation_column: i64 = db
            .connection()
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_xinfo('task_board_dispatch_intents')
                 WHERE name = 'compensation_pending'",
                [],
                |row| row.get(0),
            )
            .expect("read repaired compensation column");
        assert_eq!(compensation_column, 1);
    }

    #[test]
    fn compensation_marker_requires_a_recoverable_dispatch_and_reason() {
        let db = DaemonDb::open_in_memory().expect("open daemon db");
        seed_admission_fixture(db.connection());

        let terminal_marker = db.connection().execute(
            "UPDATE task_board_dispatch_intents
             SET last_error = 'stop worker', compensation_pending = 1
             WHERE intent_id = 'intent-a'",
            [],
        );
        assert!(terminal_marker.is_err(), "terminal marker must fail");
        let empty_reason = db.connection().execute(
            "UPDATE task_board_dispatch_intents
             SET status = 'starting', claim_token = 'claim', claimed_at = ?1,
                 completed_at = NULL, last_error = NULL, compensation_pending = 1
             WHERE intent_id = 'intent-a'",
            [NOW],
        );
        assert!(empty_reason.is_err(), "reasonless marker must fail");

        db.connection()
            .execute(
                "UPDATE task_board_dispatch_intents
                 SET status = 'starting', claim_token = 'claim', claimed_at = ?1,
                     completed_at = NULL, last_error = 'stop worker', compensation_pending = 1
                 WHERE intent_id = 'intent-a'",
                [NOW],
            )
            .expect("mark a recoverable compensation");
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

    #[test]
    fn admission_decision_generation_is_unique_per_item() {
        let db = DaemonDb::open_in_memory().expect("open daemon db");
        seed_admission_fixture(db.connection());
        insert_allowed_decision(db.connection(), "decision-a", "intent-a", 1)
            .expect("insert first decision");

        let duplicate = insert_allowed_decision(db.connection(), "decision-b", "intent-b", 1);

        assert!(duplicate.is_err(), "duplicate item generation must fail");
    }

    #[test]
    fn admission_ledger_enforces_kind_amount_and_window_shape() {
        let db = DaemonDb::open_in_memory().expect("open daemon db");
        seed_admission_fixture(db.connection());
        insert_allowed_decision(db.connection(), "decision-a", "intent-a", 1)
            .expect("insert decision");

        for (id, kind, amount, window) in [
            ("concurrency", "concurrency", 2, None),
            ("rate", "rate", 3, Some((NOW, LATER))),
            ("time-window", "time_window", 0, Some((NOW, LATER))),
            ("token", "token_budget", 4, Some((NOW, LATER))),
            ("money", "monetary_budget", 5, Some((NOW, LATER))),
        ] {
            insert_ledger(
                db.connection(),
                id,
                kind,
                amount,
                window,
                LedgerLifecycle::Reserved { expires_at: LATER },
            )
            .unwrap_or_else(|error| panic!("insert valid {kind} ledger: {error}"));
        }

        for (id, kind, amount, window) in [
            ("bad-concurrency", "concurrency", 0, None),
            ("bad-rate", "rate", 0, Some((NOW, LATER))),
            ("bad-window", "time_window", 1, Some((NOW, LATER))),
            ("bad-token", "token_budget", 0, Some((NOW, LATER))),
        ] {
            assert!(
                insert_ledger(
                    db.connection(),
                    id,
                    kind,
                    amount,
                    window,
                    LedgerLifecycle::Reserved { expires_at: LATER },
                )
                .is_err(),
                "invalid {kind} ledger must fail"
            );
        }
    }

    #[test]
    fn admission_ledger_timestamps_are_monotonic() {
        let db = DaemonDb::open_in_memory().expect("open daemon db");
        seed_admission_fixture(db.connection());
        insert_allowed_decision(db.connection(), "decision-a", "intent-a", 1)
            .expect("insert decision");

        for (id, lifecycle) in [
            (
                "expired-before-reserved",
                LedgerLifecycle::Reserved { expires_at: NOW },
            ),
            (
                "committed-before-reserved",
                LedgerLifecycle::Committed {
                    committed_at: "2026-07-17T09:59:59Z",
                },
            ),
            (
                "released-before-reserved",
                LedgerLifecycle::Released {
                    committed_at: None,
                    released_at: "2026-07-17T09:59:59Z",
                },
            ),
            (
                "committed-release-before-reserved",
                LedgerLifecycle::Released {
                    committed_at: Some("2026-07-17T09:59:58Z"),
                    released_at: "2026-07-17T09:59:59Z",
                },
            ),
        ] {
            assert!(
                insert_ledger(db.connection(), id, "concurrency", 1, None, lifecycle).is_err(),
                "non-monotonic ledger {id} must fail"
            );
        }

        insert_ledger(
            db.connection(),
            "valid-released",
            "concurrency",
            1,
            None,
            LedgerLifecycle::Released {
                committed_at: Some(NOW),
                released_at: NOW,
            },
        )
        .expect("equal monotonic timestamps are valid");
    }

    #[derive(Clone, Copy)]
    enum LedgerLifecycle<'a> {
        Reserved {
            expires_at: &'a str,
        },
        Committed {
            committed_at: &'a str,
        },
        Released {
            committed_at: Option<&'a str>,
            released_at: &'a str,
        },
    }

    fn seed_admission_fixture(conn: &Connection) {
        conn.execute_batch(
            "INSERT INTO task_board_items (
                 item_id, schema_version, title, body, status, priority, tags_json,
                 project_id, target_project_types_json, agent_mode, imported_from_provider,
                 planning_json, workflow_json, session_id, work_item_id, usage_json,
                 created_at, updated_at, deleted_at, revision, workflow_kind
             ) VALUES (
                 'item', 1, 'Item', '', 'todo', 'medium', '[]', NULL, '[]',
                 'headless', NULL, '{}', '{}', NULL, NULL, '{}',
                 '2026-07-17T10:00:00Z', '2026-07-17T10:00:00Z', NULL, 1,
                 'default_task'
             );
             INSERT INTO task_board_dispatch_intents (
                 intent_id, item_id, session_id, work_item_id, workflow_execution_id,
                 payload_json, status, attempts, available_at, created_at, updated_at,
                 completed_at
             ) VALUES
             (
                 'intent-a', 'item', 'session-a', 'work-a', 'execution-a', '{}',
                 'completed', 0, '2026-07-17T10:00:00Z', '2026-07-17T10:00:00Z',
                 '2026-07-17T10:00:00Z', '2026-07-17T10:00:00Z'
             ),
             (
                 'intent-b', 'item', 'session-b', 'work-b', 'execution-b', '{}',
                 'completed', 0, '2026-07-17T10:00:00Z', '2026-07-17T10:00:00Z',
                 '2026-07-17T10:00:00Z', '2026-07-17T10:00:00Z'
             );",
        )
        .expect("seed task-board admission fixture");
    }

    fn insert_allowed_decision(
        conn: &Connection,
        decision_id: &str,
        intent_id: &str,
        generation: i64,
    ) -> SqlResult<usize> {
        conn.execute(
            "INSERT INTO task_board_dispatch_admission_decisions (
                 decision_id, intent_id, generation, item_id, item_revision,
                 settings_revision, decision, policy_json, context_json,
                 requirements_json, blockers_json, launch_profile, evaluated_at,
                 next_available_at, is_current, superseded_at, created_at
             ) VALUES (
                 ?1, ?2, ?3, 'item', 1, 1, 'allowed', '{}', '{}', '[]', '[]',
                 'workspace_write', ?4, NULL, 0, ?4, ?4
             )",
            params![decision_id, intent_id, generation, NOW],
        )
    }

    fn insert_ledger(
        conn: &Connection,
        ledger_id: &str,
        kind: &str,
        amount: i64,
        window: Option<(&str, &str)>,
        lifecycle: LedgerLifecycle<'_>,
    ) -> SqlResult<usize> {
        let (state, worker, expires_at, committed_at, released_at) = match lifecycle {
            LedgerLifecycle::Reserved { expires_at } => {
                ("reserved", None, Some(expires_at), None, None)
            }
            LedgerLifecycle::Committed { committed_at } => {
                ("committed", Some("worker"), None, Some(committed_at), None)
            }
            LedgerLifecycle::Released {
                committed_at,
                released_at,
            } => (
                "released",
                committed_at.map(|_| "worker"),
                None,
                committed_at,
                Some(released_at),
            ),
        };
        conn.execute(
            "INSERT INTO task_board_dispatch_admission_ledger (
                 ledger_id, decision_id, decision, intent_id, generation, item_id,
                 canonical_key, kind, scope, amount, limit_value, window_started_at,
                 window_ends_at, state, managed_worker_id, expires_at, reserved_at,
                 committed_at, released_at
             ) VALUES (
                 ?1, 'decision-a', 'allowed', 'intent-a', 1, 'item', ?1, ?2,
                 'global', ?3, 10, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11
             )",
            params![
                ledger_id,
                kind,
                amount,
                window.map(|value| value.0),
                window.map(|value| value.1),
                state,
                worker,
                expires_at,
                NOW,
                committed_at,
                released_at,
            ],
        )
    }
}
