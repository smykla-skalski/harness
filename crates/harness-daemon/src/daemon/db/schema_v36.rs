use rusqlite::Connection;

use super::{CliError, db_error};

const AUTOMATION_DDL: &str = "
CREATE TABLE IF NOT EXISTS task_board_orchestrator_control (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1), desired_mode TEXT NOT NULL DEFAULT 'off',
    admission_state TEXT NOT NULL DEFAULT 'stopped', stop_generation INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS task_board_orchestrator_runs (
    run_id TEXT PRIMARY KEY, trigger TEXT NOT NULL, actor TEXT, dry_run INTEGER NOT NULL,
    scope_json TEXT NOT NULL, state TEXT NOT NULL, outcome TEXT, lease_owner TEXT NOT NULL,
    lease_epoch INTEGER NOT NULL, lease_expires_at TEXT NOT NULL, stop_generation INTEGER NOT NULL,
    started_at TEXT NOT NULL, heartbeat_at TEXT NOT NULL, completed_at TEXT,
    stage_summary_json TEXT NOT NULL DEFAULT '{}', error_kind TEXT, error TEXT,
    revision INTEGER NOT NULL DEFAULT 1
) WITHOUT ROWID;
CREATE UNIQUE INDEX IF NOT EXISTS task_board_orchestrator_runs_one_active
    ON task_board_orchestrator_runs((1)) WHERE state IN ('running', 'cancelling');
CREATE INDEX IF NOT EXISTS task_board_orchestrator_runs_completed
    ON task_board_orchestrator_runs(completed_at DESC, run_id DESC);
CREATE TABLE IF NOT EXISTS task_board_workflow_executions (
    execution_id TEXT PRIMARY KEY, item_id TEXT NOT NULL REFERENCES task_board_items(item_id)
        ON DELETE CASCADE, workflow_kind TEXT NOT NULL, phase TEXT NOT NULL, state TEXT NOT NULL,
    item_revision INTEGER NOT NULL, configuration_revision INTEGER NOT NULL,
    provider_revision TEXT, snapshot_json TEXT NOT NULL, resolved_reviewer_json TEXT NOT NULL,
    host_id TEXT, fencing_epoch INTEGER NOT NULL DEFAULT 0, available_at TEXT,
    blocked_reason TEXT, diagnostics_json TEXT NOT NULL DEFAULT '{}',
    resource_ownership_json TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL, completed_at TEXT
) WITHOUT ROWID;
CREATE UNIQUE INDEX IF NOT EXISTS task_board_workflow_executions_one_active_item
    ON task_board_workflow_executions(item_id)
    WHERE state IN ('pending', 'preparing', 'starting', 'running', 'retry_wait',
                    'awaiting_approval', 'draining');
CREATE INDEX IF NOT EXISTS task_board_workflow_executions_ready
    ON task_board_workflow_executions(state, available_at, updated_at, execution_id);
CREATE TABLE IF NOT EXISTS task_board_execution_attempts (
    execution_id TEXT NOT NULL REFERENCES task_board_workflow_executions(execution_id)
        ON DELETE CASCADE, action_key TEXT NOT NULL, attempt INTEGER NOT NULL,
    idempotency_key TEXT NOT NULL UNIQUE, state TEXT NOT NULL, failure_class TEXT,
    available_at TEXT, error TEXT, artifact_json TEXT, started_at TEXT NOT NULL,
    updated_at TEXT NOT NULL, completed_at TEXT,
    PRIMARY KEY (execution_id, action_key, attempt)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS task_board_admission_leases (
    lease_id TEXT PRIMARY KEY, execution_id TEXT NOT NULL
        REFERENCES task_board_workflow_executions(execution_id) ON DELETE CASCADE,
    phase TEXT NOT NULL, scope TEXT NOT NULL, state TEXT NOT NULL, owner TEXT NOT NULL,
    acquired_at TEXT NOT NULL, expires_at TEXT NOT NULL, released_at TEXT
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS task_board_admission_leases_active
    ON task_board_admission_leases(scope, state, expires_at);
CREATE TABLE IF NOT EXISTS task_board_provider_scope_state (
    provider TEXT NOT NULL, scope_id TEXT NOT NULL, base_revision TEXT,
    health TEXT NOT NULL DEFAULT 'healthy', failure_count INTEGER NOT NULL DEFAULT 0,
    backoff_until TEXT, updated_at TEXT NOT NULL, PRIMARY KEY (provider, scope_id)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS task_board_sync_conflicts (
    conflict_id TEXT PRIMARY KEY, item_id TEXT NOT NULL REFERENCES task_board_items(item_id)
        ON DELETE CASCADE, provider TEXT NOT NULL, external_ref TEXT NOT NULL, field TEXT NOT NULL,
    base_value_json TEXT NOT NULL, local_value_json TEXT NOT NULL,
    remote_value_json TEXT NOT NULL, item_revision INTEGER NOT NULL, provider_revision TEXT,
    state TEXT NOT NULL, detected_at TEXT NOT NULL, resolved_at TEXT, resolved_by TEXT
) WITHOUT ROWID;
CREATE UNIQUE INDEX IF NOT EXISTS task_board_sync_conflicts_one_open_field
    ON task_board_sync_conflicts(item_id, provider, external_ref, field) WHERE state = 'open';
CREATE TABLE IF NOT EXISTS task_board_execution_hosts (
    host_id TEXT PRIMARY KEY, endpoint TEXT NOT NULL, certificate_fingerprint TEXT NOT NULL,
    credential_reference TEXT NOT NULL, protocol_version INTEGER NOT NULL,
    capabilities_json TEXT NOT NULL, repositories_json TEXT NOT NULL, capacity INTEGER NOT NULL,
    active_assignments INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL,
    heartbeat_at TEXT NOT NULL, updated_at TEXT NOT NULL
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS task_board_remote_assignments (
    assignment_id TEXT PRIMARY KEY, execution_id TEXT NOT NULL
        REFERENCES task_board_workflow_executions(execution_id) ON DELETE CASCADE,
    phase TEXT NOT NULL, host_id TEXT NOT NULL REFERENCES task_board_execution_hosts(host_id),
    idempotency_key TEXT NOT NULL UNIQUE, fencing_epoch INTEGER NOT NULL, state TEXT NOT NULL,
    offered_at TEXT NOT NULL, acknowledged_at TEXT, started_at TEXT, heartbeat_at TEXT,
    completed_at TEXT, result_json TEXT, error TEXT
) WITHOUT ROWID;
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_assignments_one_active_phase
    ON task_board_remote_assignments(execution_id, phase)
    WHERE state IN ('offered', 'claimed', 'started', 'running', 'unknown');
CREATE TABLE IF NOT EXISTS task_board_orchestrator_wake_events (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT, cause TEXT NOT NULL, entity_id TEXT,
    entity_revision INTEGER, payload_json TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL,
    processed_at TEXT
);
CREATE INDEX IF NOT EXISTS task_board_orchestrator_wake_events_pending
    ON task_board_orchestrator_wake_events(processed_at, sequence);
";

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    add_column_if_missing(
        conn,
        "task_board_items",
        "workflow_kind",
        "workflow_kind TEXT NOT NULL DEFAULT 'unknown'",
    )?;
    add_column_if_missing(
        conn,
        "task_board_items",
        "execution_repository",
        "execution_repository TEXT",
    )?;
    conn.execute(
        "UPDATE task_board_items SET workflow_kind = 'default_task'
         WHERE workflow_kind = 'unknown'
           AND (imported_from_provider IS NULL OR imported_from_provider = 'todoist')",
        [],
    )
    .map_err(|error| db_error(format!("backfill v36 workflow kinds: {error}")))?;
    conn.execute_batch(AUTOMATION_DDL)
        .map_err(|error| db_error(format!("create v36 automation schema: {error}")))?;
    conn.execute(
        "UPDATE schema_meta SET value = '36' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| db_error(format!("stamp schema v36: {error}")))
}

fn add_column_if_missing(
    conn: &Connection,
    table: &str,
    column: &str,
    definition: &str,
) -> Result<(), CliError> {
    if column_exists(conn, table, column)? {
        return Ok(());
    }
    conn.execute(&format!("ALTER TABLE {table} ADD COLUMN {definition}"), [])
        .map(|_| ())
        .map_err(|error| db_error(format!("add {table}.{column}: {error}")))
}

fn column_exists(conn: &Connection, table: &str, column: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
        [table, column],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check {table}.{column}: {error}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migration_adds_durable_automation_contracts() {
        let conn = Connection::open_in_memory().expect("open sqlite");
        conn.execute_batch(
            "CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO schema_meta VALUES ('version', '35');
             CREATE TABLE task_board_items (
                 item_id TEXT PRIMARY KEY,
                 imported_from_provider TEXT
             );
             INSERT INTO task_board_items VALUES ('manual-item', NULL);
             INSERT INTO task_board_items VALUES ('remote-item', 'github');",
        )
        .expect("seed v35 shape");

        run(&conn).expect("run v36 migration");

        let manual_kind: String = conn
            .query_row(
                "SELECT workflow_kind FROM task_board_items WHERE item_id = 'manual-item'",
                [],
                |row| row.get(0),
            )
            .expect("manual workflow kind");
        let remote_kind: String = conn
            .query_row(
                "SELECT workflow_kind FROM task_board_items WHERE item_id = 'remote-item'",
                [],
                |row| row.get(0),
            )
            .expect("remote workflow kind");
        assert_eq!(manual_kind, "default_task");
        assert_eq!(remote_kind, "unknown");
        assert!(column_exists(&conn, "task_board_items", "execution_repository").unwrap());
        assert!(column_exists(&conn, "task_board_orchestrator_runs", "lease_epoch").unwrap());
    }
}
