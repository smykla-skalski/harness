use rusqlite::Connection;

use super::{CliError, db_error};

const BACKLOG_MIGRATION_SQL: &str =
    include_str!("migrations/0031_daemon_v37_task_board_backlog.sql");

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(BACKLOG_MIGRATION_SQL)
        .map_err(|error| db_error(format!("migrate task board umbrella statuses: {error}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::db::DaemonDb;

    #[test]
    fn migration_rewrites_only_persisted_task_board_status_fields() {
        let db = DaemonDb::open_in_memory().expect("open daemon db");
        seed_legacy_umbrella_rows(db.connection());

        run(db.connection()).expect("run backlog migration");

        assert_eq!(db.schema_version().expect("schema version"), "37");
        assert_eq!(
            text(
                db.connection(),
                "SELECT status FROM task_board_items WHERE item_id = 'legacy-item'"
            ),
            "backlog"
        );
        assert_eq!(
            text(
                db.connection(),
                "SELECT status FROM task_board_items WHERE item_id = 'prioritized-item'"
            ),
            "todo",
            "the migration must not move existing prioritized Todo items"
        );
        for query in backlog_json_queries() {
            assert_eq!(text(db.connection(), query), "backlog", "{query}");
        }
        assert_eq!(
            text(
                db.connection(),
                "SELECT json_extract(stage_summary_json, '$.label')
                 FROM task_board_orchestrator_runs"
            ),
            "umbrella",
            "non-status text must not be rewritten"
        );
    }

    fn seed_legacy_umbrella_rows(conn: &Connection) {
        conn.execute_batch(
            "INSERT INTO task_board_items (
                 item_id, schema_version, title, body, status, priority, tags_json,
                 project_id, target_project_types_json, agent_mode, imported_from_provider,
                 planning_json, workflow_json, session_id, work_item_id, usage_json,
                 created_at, updated_at, deleted_at, revision, workflow_kind
             ) VALUES
             (
                 'legacy-item', 1, 'Legacy', '', 'umbrella', 'medium', '[]',
                 NULL, '[]', 'headless', 'github', '{}', '{}', NULL, NULL, '{}',
                 '2026-07-16T00:00:00Z', '2026-07-16T00:00:00Z', NULL, 1, 'review'
             ),
             (
                 'prioritized-item', 1, 'Prioritized', '', 'todo', 'high', '[]',
                 NULL, '[]', 'headless', NULL, '{}', '{}', NULL, NULL, '{}',
                 '2026-07-16T00:00:00Z', '2026-07-16T00:00:00Z', NULL, 1, 'default_task'
             );
             INSERT INTO task_board_external_refs (
                 item_id, position, provider, external_id, sync_state_json
             ) VALUES (
                 'legacy-item', 0, 'github', '42', '{\"status\":\"umbrella\"}'
             );
             INSERT INTO task_board_orchestrator_settings (
                 singleton, settings_json, revision, updated_at
             ) VALUES (
                 1, '{\"dispatch_status_filter\":\"umbrella\"}', 1,
                 '2026-07-16T00:00:00Z'
             );
             INSERT INTO task_board_orchestrator_state (
                 singleton, state_json, enabled, running, revision, updated_at
             ) VALUES (
                 1, '{\"last_run\":{\"audit\":{\"by_status\":[{\"status\":\"umbrella\"}]},
                 \"evaluation\":{\"records\":[{\"board_status\":\"umbrella\",
                 \"item\":{\"status\":\"umbrella\"}}]}}}', 0, 0, 1,
                 '2026-07-16T00:00:00Z'
             );
             INSERT INTO task_board_orchestrator_runs (
                 run_id, trigger, dry_run, scope_json, state, lease_owner, lease_epoch,
                 lease_expires_at, stop_generation, started_at, heartbeat_at,
                 stage_summary_json, revision
             ) VALUES (
                 'legacy-run', 'manual', 0, '{\"status\":\"umbrella\"}', 'terminal',
                 'host', 1, '2026-07-16T01:00:00Z', 0, '2026-07-16T00:00:00Z',
                 '2026-07-16T00:00:00Z',
                 '{\"status\":\"umbrella\",\"label\":\"umbrella\"}', 1
             );
             INSERT INTO task_board_dispatch_intents (
                 intent_id, item_id, session_id, work_item_id, workflow_execution_id,
                 payload_json, status, attempts, available_at, created_at, updated_at
             ) VALUES (
                 'legacy-intent', 'legacy-item', 'session', 'work', 'execution',
                 '{\"item\":{\"status\":\"umbrella\"},
                 \"readiness\":{\"reason\":{\"status\":\"umbrella\"}}}',
                 'pending', 0, '2026-07-16T00:00:00Z', '2026-07-16T00:00:00Z',
                 '2026-07-16T00:00:00Z'
             );
             INSERT INTO task_board_sync_conflicts (
                 conflict_id, item_id, provider, external_ref, field, base_value_json,
                 local_value_json, remote_value_json, item_revision, state, detected_at
             ) VALUES (
                 'legacy-conflict', 'legacy-item', 'github', '42', 'status',
                 '\"umbrella\"', '\"umbrella\"', '\"umbrella\"', 1, 'open',
                 '2026-07-16T00:00:00Z'
             );",
        )
        .expect("seed legacy task board statuses");
    }

    fn backlog_json_queries() -> [&'static str; 12] {
        [
            "SELECT json_extract(sync_state_json, '$.status') FROM task_board_external_refs",
            "SELECT json_extract(settings_json, '$.dispatch_status_filter')
             FROM task_board_orchestrator_settings",
            "SELECT json_extract(state_json, '$.last_run.audit.by_status[0].status')
             FROM task_board_orchestrator_state",
            "SELECT json_extract(state_json, '$.last_run.evaluation.records[0].board_status')
             FROM task_board_orchestrator_state",
            "SELECT json_extract(state_json, '$.last_run.evaluation.records[0].item.status')
             FROM task_board_orchestrator_state",
            "SELECT json_extract(scope_json, '$.status') FROM task_board_orchestrator_runs",
            "SELECT json_extract(stage_summary_json, '$.status')
             FROM task_board_orchestrator_runs",
            "SELECT json_extract(payload_json, '$.item.status')
             FROM task_board_dispatch_intents",
            "SELECT json_extract(payload_json, '$.readiness.reason.status')
             FROM task_board_dispatch_intents",
            "SELECT json_extract(base_value_json, '$') FROM task_board_sync_conflicts",
            "SELECT json_extract(local_value_json, '$') FROM task_board_sync_conflicts",
            "SELECT json_extract(remote_value_json, '$') FROM task_board_sync_conflicts",
        ]
    }

    fn text(conn: &Connection, query: &str) -> String {
        conn.query_row(query, [], |row| row.get(0))
            .expect("read migrated value")
    }
}
