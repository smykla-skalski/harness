use tempfile::tempdir;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};

const DROP_V50_SQL: &str = "
ALTER TABLE codex_runs RENAME TO codex_runs_v50;
CREATE TABLE codex_runs (
    run_id                  TEXT PRIMARY KEY,
    session_id              TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    task_id                 TEXT,
    board_item_id           TEXT,
    workflow_execution_id   TEXT,
    session_agent_id        TEXT,
    display_name            TEXT,
    project_dir             TEXT NOT NULL,
    thread_id               TEXT,
    turn_id                 TEXT,
    mode                    TEXT NOT NULL,
    status                  TEXT NOT NULL,
    prompt                  TEXT NOT NULL,
    latest_summary          TEXT,
    final_message           TEXT,
    error                   TEXT,
    pending_approvals_json  TEXT NOT NULL DEFAULT '[]',
    resolved_approvals_json TEXT NOT NULL DEFAULT '[]',
    events_json             TEXT NOT NULL DEFAULT '[]',
    created_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL,
    model                   TEXT,
    effort                  TEXT
) WITHOUT ROWID;
INSERT INTO codex_runs (
    run_id, session_id, task_id, board_item_id, workflow_execution_id,
    session_agent_id, display_name, project_dir, thread_id, turn_id, mode,
    status, prompt, latest_summary, final_message, error,
    pending_approvals_json, resolved_approvals_json, events_json,
    created_at, updated_at, model, effort
)
SELECT run_id, session_id, task_id, board_item_id, workflow_execution_id,
       session_agent_id, display_name, project_dir, thread_id, turn_id, mode,
       status, prompt, latest_summary, final_message, error,
       pending_approvals_json, resolved_approvals_json, events_json,
       created_at, updated_at, model, effort
FROM codex_runs_v50;
DROP TABLE codex_runs_v50;
CREATE INDEX idx_codex_runs_session_updated
    ON codex_runs(session_id, updated_at DESC);
CREATE INDEX idx_codex_runs_status
    ON codex_runs(status);
UPDATE schema_meta SET value = '49' WHERE key = 'version';";

/// Seeds one project, one session, and one `codex_runs` row with every
/// column set to a value distinct from every other column, so a
/// same-arity transposition in the migration's `INSERT ... SELECT` column
/// list fails a round-trip assertion instead of silently passing over an
/// empty table.
fn seed_one_codex_run(db: &DaemonDb) {
    db.connection()
        .execute(
            "INSERT INTO projects (
                 project_id, name, checkout_id, checkout_name, context_root,
                 is_worktree, discovered_at, updated_at
             ) VALUES (
                 'project-round-trip-1', 'harness', 'checkout-1', 'main',
                 '/tmp/harness-schema-v50-test', 0, '2026-07-24T00:00:00Z',
                 '2026-07-24T00:00:00Z'
             )",
            [],
        )
        .expect("seed one project");
    db.connection()
        .execute(
            "INSERT INTO sessions (
                 session_id, project_id, schema_version, context, status,
                 created_at, updated_at, state_json
             ) VALUES (
                 'session-round-trip-1', 'project-round-trip-1', 3,
                 'schema v50 round trip', 'active',
                 '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z', '{}'
             )",
            [],
        )
        .expect("seed one session");
    db.connection()
        .execute(
            "INSERT INTO codex_runs (
                 run_id, session_id, task_id, board_item_id, workflow_execution_id,
                 session_agent_id, display_name, project_dir, thread_id, turn_id, mode,
                 status, prompt, latest_summary, final_message, error,
                 pending_approvals_json, resolved_approvals_json, events_json,
                 created_at, updated_at, model, effort
             ) VALUES (
                 'codex-run-round-trip-1', 'session-round-trip-1', 'task-1', 'board-item-1',
                 'workflow-1', 'agent-1', 'Round Trip Codex', '/tmp/round-trip-project',
                 'thread-1', 'turn-1', 'approval',
                 'running', 'Investigate the round trip.', 'Working', NULL, NULL,
                 '[]', '[]', '[]',
                 '2026-07-24T00:00:01Z', '2026-07-24T00:00:02Z', 'gpt-5.5', 'high'
             )",
            [],
        )
        .expect("seed one codex run");
}

fn assert_seeded_codex_run_round_tripped(db: &DaemonDb) {
    let row: (
        String,
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        String,
        Option<String>,
        Option<String>,
        String,
        String,
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        String,
        String,
    ) = db
        .connection()
        .query_row(
            "SELECT run_id, session_id, task_id, board_item_id, workflow_execution_id,
                    session_agent_id, display_name, project_dir, thread_id, turn_id, mode,
                    status, prompt, latest_summary, final_message, error, model, effort,
                    created_at, updated_at
             FROM codex_runs WHERE run_id = 'codex-run-round-trip-1'",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                    row.get(8)?,
                    row.get(9)?,
                    row.get(10)?,
                    row.get(11)?,
                    row.get(12)?,
                    row.get(13)?,
                    row.get(14)?,
                    row.get(15)?,
                    row.get(16)?,
                    row.get(17)?,
                    row.get(18)?,
                    row.get(19)?,
                ))
            },
        )
        .expect("load round-tripped codex run");
    assert_eq!(row.1, "session-round-trip-1");
    assert_eq!(row.2.as_deref(), Some("task-1"));
    assert_eq!(row.3.as_deref(), Some("board-item-1"));
    assert_eq!(row.4.as_deref(), Some("workflow-1"));
    assert_eq!(row.5.as_deref(), Some("agent-1"));
    assert_eq!(row.6.as_deref(), Some("Round Trip Codex"));
    assert_eq!(row.7, "/tmp/round-trip-project");
    assert_eq!(row.8.as_deref(), Some("thread-1"));
    assert_eq!(row.9.as_deref(), Some("turn-1"));
    assert_eq!(row.10, "approval");
    assert_eq!(row.11, "running");
    assert_eq!(row.12, "Investigate the round trip.");
    assert_eq!(row.13.as_deref(), Some("Working"));
    assert_eq!(row.14, None);
    assert_eq!(row.15, None);
    assert_eq!(row.16.as_deref(), Some("gpt-5.5"));
    assert_eq!(row.17.as_deref(), Some("high"));
    assert_eq!(row.18, "2026-07-24T00:00:01Z");
    assert_eq!(row.19, "2026-07-24T00:00:02Z");
}

#[test]
fn fresh_schema_allows_a_null_codex_run_session() {
    let db = DaemonDb::open_in_memory().expect("open current database");

    assert_eq!(
        db.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    db.connection()
        .execute(
            "INSERT INTO codex_runs (
                 run_id, session_id, project_dir, mode, status, prompt,
                 created_at, updated_at
             ) VALUES (
                 'codex-run-null-session', NULL, '/tmp/standalone', 'report',
                 'queued', 'standalone prompt', '2026-07-24T00:00:00Z',
                 '2026-07-24T00:00:00Z'
             )",
            [],
        )
        .expect("insert a session-less codex run on the fresh v50 schema");
}

#[test]
fn v49_database_migrates_to_v50_and_restarts() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current database");
    seed_one_codex_run(&db);
    db.connection()
        .execute_batch(DROP_V50_SQL)
        .expect("restore v49 schema");
    drop(db);

    let reopened = DaemonDb::open(&path).expect("migrate v49 database");
    assert_eq!(
        reopened.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    assert_seeded_codex_run_round_tripped(&reopened);
    drop(reopened);

    let restarted = DaemonDb::open(&path).expect("restart migrated database");
    assert_eq!(
        restarted.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    assert_seeded_codex_run_round_tripped(&restarted);
}

#[tokio::test]
async fn async_upgrade_records_v50_migration() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = DaemonDb::open(&path).expect("open current v49 database");
    seed_one_codex_run(&db);
    db.connection()
        .execute_batch(DROP_V50_SQL)
        .expect("restore v49 schema");
    drop(db);

    let async_db = AsyncDaemonDb::connect(&path)
        .await
        .expect("upgrade v49 database asynchronously");

    assert_eq!(
        async_db.schema_version().await.expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    let sync_db = DaemonDb::open(&path).expect("reopen synchronously to verify round-trip");
    assert_seeded_codex_run_round_tripped(&sync_db);
}
