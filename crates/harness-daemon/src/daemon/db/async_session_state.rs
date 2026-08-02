use sqlx::query_as;

use super::async_writes::sync_session_in_transaction;
use super::{AsyncDaemonDb, AsyncDaemonTransactions, CliError, SessionState, db_error};
use crate::session::storage;
use harness_kernel::errors::CliErrorKind;

const LOAD_SESSION_STATE_SQL: &str =
    "SELECT state_json, project_id FROM sessions WHERE session_id = ?1";

/// Session-state load and immediate-transaction mutate-and-save through the
/// canonical async daemon DB.
pub(crate) trait AsyncSessionStateQueries: Send + Sync {
    /// Load session state by ID, including archived sessions.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    async fn load_session_state(&self, session_id: &str) -> Result<Option<SessionState>, CliError>;

    /// Load, mutate, and save session state under an immediate transaction.
    ///
    /// This serializes async mutation writers before they read state, avoiding
    /// lost updates when independent HTTP/WebSocket requests mutate the same
    /// session concurrently.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL, parse, or mutation failures.
    async fn update_session_state_immediate<F, T>(
        &self,
        session_id: &str,
        update: F,
    ) -> Result<T, CliError>
    where
        F: FnOnce(&mut SessionState) -> Result<T, CliError>;
}

impl AsyncSessionStateQueries for AsyncDaemonDb {
    async fn load_session_state(&self, session_id: &str) -> Result<Option<SessionState>, CliError> {
        storage::validate_session_id(session_id)?;
        let row = query_as::<_, AsyncSessionStateRow>(LOAD_SESSION_STATE_SQL)
            .bind(session_id)
            .fetch_optional(self.pool())
            .await
            .map_err(|error| db_error(format!("load async session state {session_id}: {error}")))?;
        row.map(|row| {
            serde_json::from_str(&row.state_json)
                .map_err(|error| db_error(format!("parse session state: {error}")))
        })
        .transpose()
    }

    async fn update_session_state_immediate<F, T>(
        &self,
        session_id: &str,
        update: F,
    ) -> Result<T, CliError>
    where
        F: FnOnce(&mut SessionState) -> Result<T, CliError>,
    {
        let mut transaction = self
            .begin_immediate_transaction("async immediate session mutation")
            .await?;
        let row = query_as::<_, AsyncSessionStateRow>(LOAD_SESSION_STATE_SQL)
            .bind(session_id)
            .fetch_optional(transaction.as_mut())
            .await
            .map_err(|error| {
                db_error(format!(
                    "load async session for mutation {session_id}: {error}"
                ))
            })?
            .ok_or_else(|| {
                CliError::from(CliErrorKind::session_not_active(format!(
                    "harness session '{session_id}' not found"
                )))
            })?;
        let mut state: SessionState = serde_json::from_str(&row.state_json)
            .map_err(|error| db_error(format!("parse session state: {error}")))?;
        let result = update(&mut state)?;
        sync_session_in_transaction(&mut transaction, &row.project_id, &state).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit async immediate session mutation transaction: {error}"
            ))
        })?;
        Ok(result)
    }
}

#[derive(sqlx::FromRow)]
struct AsyncSessionStateRow {
    state_json: String,
    project_id: String,
}
