//! Rebuild `SQLite` mirror tables from file-backed state.
//!
//! When the daemon restarts, durable JSONL artifacts such as
//! `tasks/<task_id>/reviews.jsonl` may contain rows that never made it into
//! the database (crash between file append and SQL insert, or an older
//! daemon that had no `task_reviews` table yet). This module rebuilds the
//! `SQLite` mirror from the file truth so the daemon starts with a consistent
//! view.

use rusqlite::params;

use super::{CliError, DaemonDb, db_error};
use crate::session::types::Review;

impl DaemonDb {
    /// Replace every row in `task_reviews` for `(session_id, task_id)` with
    /// the supplied `reviews`. Safe to call on daemon start to rebuild the
    /// `SQLite` mirror from `reviews.jsonl`.
    ///
    /// The function deletes existing rows first so stale records left by a
    /// previous schema or a partial import are dropped before the fresh
    /// inserts. Each insert uses `INSERT OR REPLACE` so repeated calls with
    /// the same review ids remain idempotent.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) fn rebuild_task_reviews(
        &self,
        session_id: &str,
        task_id: &str,
        reviews: &[Review],
    ) -> Result<(), CliError> {
        let transaction = self
            .conn
            .unchecked_transaction()
            .map_err(|error| db_error(format!("begin rebuild task_reviews transaction: {error}")))?;
        transaction
            .execute(
                "DELETE FROM task_reviews WHERE session_id = ?1 AND task_id = ?2",
                params![session_id, task_id],
            )
            .map_err(|error| db_error(format!("clear task_reviews for rebuild: {error}")))?;
        for review in reviews {
            let points_json = serde_json::to_string(&review.points).map_err(|error| {
                db_error(format!(
                    "serialize review points for {}: {error}",
                    review.review_id
                ))
            })?;
            let verdict = serde_json::to_value(review.verdict)
                .ok()
                .and_then(|value| value.as_str().map(ToOwned::to_owned))
                .ok_or_else(|| db_error("serialize review verdict"))?;
            transaction
                .execute(
                    "INSERT OR REPLACE INTO task_reviews (
                        review_id, session_id, task_id, round,
                        reviewer_agent_id, reviewer_runtime, verdict,
                        summary, points_json, recorded_at
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                    params![
                        review.review_id,
                        session_id,
                        task_id,
                        i64::from(review.round),
                        review.reviewer_agent_id,
                        review.reviewer_runtime,
                        verdict,
                        review.summary,
                        points_json,
                        review.recorded_at,
                    ],
                )
                .map_err(|error| {
                    db_error(format!(
                        "insert task review {}: {error}",
                        review.review_id
                    ))
                })?;
        }
        transaction
            .commit()
            .map_err(|error| db_error(format!("commit rebuild task_reviews transaction: {error}")))
    }

    /// Number of `task_reviews` rows currently stored for a task.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    #[cfg(test)]
    pub(crate) fn count_task_reviews(
        &self,
        session_id: &str,
        task_id: &str,
    ) -> Result<i64, CliError> {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM task_reviews WHERE session_id = ?1 AND task_id = ?2",
                params![session_id, task_id],
                |row| row.get::<_, i64>(0),
            )
            .map_err(|error| db_error(format!("count task_reviews: {error}")))
    }

    /// Fetch a single review row's round + verdict + review id, ordered by
    /// `recorded_at`. Used by tests to assert rebuild fidelity.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    #[cfg(test)]
    pub(crate) fn list_task_review_summaries(
        &self,
        session_id: &str,
        task_id: &str,
    ) -> Result<Vec<(String, i64, String)>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT review_id, round, verdict FROM task_reviews \
                 WHERE session_id = ?1 AND task_id = ?2 \
                 ORDER BY recorded_at, review_id",
            )
            .map_err(|error| db_error(format!("prepare list task_reviews: {error}")))?;
        let rows = statement
            .query_map(params![session_id, task_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })
            .map_err(|error| db_error(format!("query task_reviews: {error}")))?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row.map_err(|error| db_error(format!("read task_reviews row: {error}")))?);
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::types::{ReviewPoint, ReviewPointState, ReviewVerdict};

    fn seed_session(db: &DaemonDb) {
        db.connection()
            .execute(
                "INSERT OR IGNORE INTO projects (\
                    project_id, name, project_dir, repository_root, checkout_id, \
                    checkout_name, context_root, is_worktree, worktree_name, \
                    discovered_at, updated_at\
                ) VALUES ('proj-1','demo',NULL,NULL,'co-1','demo','/ctx/proj-1',0,NULL,\
                    '2026-04-20T00:00:00Z','2026-04-20T00:00:00Z')",
                [],
            )
            .expect("seed project");
        db.connection()
            .execute(
                "INSERT INTO sessions (\
                    session_id, project_id, schema_version, state_version, context, \
                    status, created_at, updated_at, state_json\
                ) VALUES ('sess-1','proj-1',10,1,'ctx','active','2026-04-20T00:00:00Z','2026-04-20T00:00:00Z','{}')",
                [],
            )
            .expect("seed session");
    }

    fn review_fixture(review_id: &str, round: u8, verdict: ReviewVerdict) -> Review {
        Review {
            review_id: review_id.to_string(),
            round,
            reviewer_agent_id: "rev-1".into(),
            reviewer_runtime: "claude".into(),
            verdict,
            summary: "summary".into(),
            points: vec![ReviewPoint {
                point_id: "p1".into(),
                text: "fix".into(),
                state: ReviewPointState::Open,
                worker_note: None,
            }],
            recorded_at: format!("2026-04-20T00:00:0{round}Z"),
        }
    }

    #[test]
    fn rebuild_replaces_existing_rows_with_file_contents() {
        let db = DaemonDb::open_in_memory().expect("open db");
        // Seed a session so the foreign key resolves.
        seed_session(&db);

        let first = vec![review_fixture("r1", 1, ReviewVerdict::Approve)];
        db.rebuild_task_reviews("sess-1", "task-1", &first)
            .expect("rebuild once");
        assert_eq!(
            db.count_task_reviews("sess-1", "task-1").expect("count"),
            1
        );

        let second = vec![
            review_fixture("r1", 1, ReviewVerdict::Approve),
            review_fixture("r2", 2, ReviewVerdict::RequestChanges),
        ];
        db.rebuild_task_reviews("sess-1", "task-1", &second)
            .expect("rebuild twice");
        let summaries = db
            .list_task_review_summaries("sess-1", "task-1")
            .expect("list");
        assert_eq!(
            summaries,
            vec![
                ("r1".to_string(), 1, "approve".to_string()),
                ("r2".to_string(), 2, "request_changes".to_string()),
            ]
        );
    }

    #[test]
    fn rebuild_with_empty_slice_clears_existing_rows() {
        let db = DaemonDb::open_in_memory().expect("open db");
        seed_session(&db);
        db.rebuild_task_reviews(
            "sess-1",
            "task-1",
            &[review_fixture("r1", 1, ReviewVerdict::Approve)],
        )
        .expect("seed rebuild");
        assert_eq!(
            db.count_task_reviews("sess-1", "task-1").expect("count"),
            1
        );
        db.rebuild_task_reviews("sess-1", "task-1", &[])
            .expect("clear rebuild");
        assert_eq!(
            db.count_task_reviews("sess-1", "task-1").expect("count"),
            0
        );
    }

    #[test]
    fn rebuild_only_affects_the_target_task() {
        let db = DaemonDb::open_in_memory().expect("open db");
        seed_session(&db);
        db.rebuild_task_reviews(
            "sess-1",
            "task-a",
            &[review_fixture("ra", 1, ReviewVerdict::Approve)],
        )
        .expect("rebuild task a");
        db.rebuild_task_reviews(
            "sess-1",
            "task-b",
            &[review_fixture("rb", 1, ReviewVerdict::RequestChanges)],
        )
        .expect("rebuild task b");

        // Clearing task-b must leave task-a intact.
        db.rebuild_task_reviews("sess-1", "task-b", &[])
            .expect("clear task b");
        assert_eq!(
            db.count_task_reviews("sess-1", "task-a").expect("count a"),
            1
        );
        assert_eq!(
            db.count_task_reviews("sess-1", "task-b").expect("count b"),
            0
        );
    }
}
