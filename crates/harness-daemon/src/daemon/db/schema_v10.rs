use rusqlite::Connection;

use super::{CliError, db_error};

const ALTER_STATEMENTS: &[&str] = &[
    "ALTER TABLE tasks ADD COLUMN awaiting_review_queued_at TEXT",
    "ALTER TABLE tasks ADD COLUMN awaiting_review_submitter_agent_id TEXT",
    "ALTER TABLE tasks ADD COLUMN awaiting_review_required_consensus INTEGER NOT NULL DEFAULT 2",
    "ALTER TABLE tasks ADD COLUMN review_round INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE tasks ADD COLUMN review_claim_json TEXT",
    "ALTER TABLE tasks ADD COLUMN consensus_json TEXT",
    "ALTER TABLE tasks ADD COLUMN arbitration_json TEXT",
    "ALTER TABLE tasks ADD COLUMN suggested_persona TEXT",
];

const TASK_REVIEWS_DDL: &str = "CREATE TABLE IF NOT EXISTS task_reviews (
    review_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    task_id TEXT NOT NULL,
    round INTEGER NOT NULL,
    reviewer_agent_id TEXT NOT NULL,
    reviewer_runtime TEXT NOT NULL,
    verdict TEXT NOT NULL,
    summary TEXT NOT NULL,
    points_json TEXT NOT NULL,
    recorded_at TEXT NOT NULL,
    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
 );
 CREATE INDEX IF NOT EXISTS idx_task_reviews_task ON task_reviews(session_id, task_id);";

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    if tasks_table_exists(conn)? {
        for statement in ALTER_STATEMENTS {
            if let Err(error) = conn.execute(statement, []) {
                let message = error.to_string();
                if !message.contains("duplicate column name") {
                    return Err(db_error(format!(
                        "migrate v9 -> v10 ({statement}): {error}"
                    )));
                }
            }
        }
    }
    conn.execute_batch(TASK_REVIEWS_DDL)
        .map_err(|error| db_error(format!("migrate v9 -> v10 (task_reviews): {error}")))?;
    conn.execute(
        "UPDATE schema_meta SET value = '10' WHERE key = 'version'",
        [],
    )
    .map_err(|error| db_error(format!("bump schema version to v10: {error}")))?;
    Ok(())
}

fn tasks_table_exists(conn: &Connection) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='tasks'",
        [],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check tasks table existence: {error}")))
}
