//! Single-row `task_reviews` mirror writes.
//!
//! Complements `rebuild.rs` (which replaces all rows for a task from the
//! file truth on daemon start) with per-review inserts used inline by the
//! `submit_review` mutation wrappers. Keeping these writes immediate on
//! both the sync and async paths means a fresh daemon request surfaces
//! in `SQLite` without needing a restart or resync.

use rusqlite::params;
use sqlx::query;
#[cfg(test)]
use sqlx::query_scalar;

use super::{AsyncDaemonDb, CliError, DaemonDb, db_error};
use crate::session::types::Review;

const INSERT_TASK_REVIEW_SQL: &str = "INSERT OR REPLACE INTO task_reviews (\n        review_id, session_id, task_id, round,\n        reviewer_agent_id, reviewer_runtime, verdict,\n        summary, points_json, recorded_at\n    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)";

fn serialize_points(review: &Review) -> Result<String, CliError> {
    serde_json::to_string(&review.points).map_err(|error| {
        db_error(format!(
            "serialize review points for {}: {error}",
            review.review_id
        ))
    })
}

fn serialize_verdict(review: &Review) -> Result<String, CliError> {
    serde_json::to_value(review.verdict)
        .ok()
        .and_then(|value| value.as_str().map(ToOwned::to_owned))
        .ok_or_else(|| db_error("serialize review verdict"))
}

impl DaemonDb {
    /// Insert a single `task_reviews` row (sync path). Idempotent on `review_id`.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or serialization failure.
    pub(crate) fn insert_task_review(
        &self,
        session_id: &str,
        task_id: &str,
        review: &Review,
    ) -> Result<(), CliError> {
        let points_json = serialize_points(review)?;
        let verdict = serialize_verdict(review)?;
        self.connection()
            .execute(
                INSERT_TASK_REVIEW_SQL,
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
            .map(|_| ())
            .map_err(|error| {
                db_error(format!(
                    "insert task review {}: {error}",
                    review.review_id
                ))
            })
    }
}

impl AsyncDaemonDb {
    /// Insert a single `task_reviews` row (async path). Idempotent on `review_id`.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or serialization failure.
    pub(crate) async fn insert_task_review(
        &self,
        session_id: &str,
        task_id: &str,
        review: &Review,
    ) -> Result<(), CliError> {
        let points_json = serialize_points(review)?;
        let verdict = serialize_verdict(review)?;
        query(INSERT_TASK_REVIEW_SQL)
            .bind(&review.review_id)
            .bind(session_id)
            .bind(task_id)
            .bind(i64::from(review.round))
            .bind(&review.reviewer_agent_id)
            .bind(&review.reviewer_runtime)
            .bind(verdict)
            .bind(&review.summary)
            .bind(points_json)
            .bind(&review.recorded_at)
            .execute(self.pool())
            .await
            .map_err(|error| {
                db_error(format!(
                    "insert async task review {}: {error}",
                    review.review_id
                ))
            })?;
        Ok(())
    }

    /// Number of `task_reviews` rows for `(session_id, task_id)`. Used by tests
    /// to assert that a live `submit_review_async` mutation mirrored into SQLite
    /// without requiring a rebuild or resync.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    #[cfg(test)]
    pub(crate) async fn count_task_reviews(
        &self,
        session_id: &str,
        task_id: &str,
    ) -> Result<i64, CliError> {
        query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM task_reviews WHERE session_id = ?1 AND task_id = ?2",
        )
        .bind(session_id)
        .bind(task_id)
        .fetch_one(self.pool())
        .await
        .map_err(|error| db_error(format!("count async task_reviews: {error}")))
    }
}
