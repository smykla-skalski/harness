use std::future::Future;

use harness_daemon_db_core::{AsyncDaemonDb, db_error};
use harness_daemon_session_service::ExpiredPendingSignalIndexRecord;
use harness_kernel::errors::CliError;
use harness_protocol::agent::Signal;
use harness_protocol::session::{SessionSignalRecord, SessionSignalStatus};
use harness_session::wire::AgentToolActivitySummary;
use sqlx::{query_as, query_scalar};

use crate::signals::derive_effective_signal_status;

const LOAD_SIGNALS_SQL: &str = "
SELECT signal_json, ack_json, runtime, agent_id, session_id, status
FROM signal_index
WHERE session_id = ?1
ORDER BY created_at DESC";
const LOAD_ACTIVITY_SQL: &str = "
SELECT activity_json
FROM agent_activity_cache
WHERE session_id = ?1
ORDER BY agent_id";
const LOAD_EXPIRED_PENDING_SIGNALS_SQL: &str = "
SELECT signal_json, runtime, agent_id
FROM signal_index
WHERE session_id = ?1 AND status = 'pending'
ORDER BY created_at DESC";

/// Async mirror of `signals::SignalIndexQueries`'s reads, plus the cached
/// agent-activity read, through the canonical async daemon DB.
pub trait AsyncSignalReadQueries: Send + Sync {
    /// # Errors
    /// Returns [`CliError`] on query or JSON parse failure.
    fn load_signals(
        &self,
        session_id: &str,
    ) -> impl Future<Output = Result<Vec<SessionSignalRecord>, CliError>> + Send;

    /// # Errors
    /// Returns [`CliError`] on query or JSON parse failure.
    fn load_agent_activity(
        &self,
        session_id: &str,
    ) -> impl Future<Output = Result<Vec<AgentToolActivitySummary>, CliError>> + Send;

    /// # Errors
    /// Returns [`CliError`] on query or JSON parse failure.
    fn load_expired_pending_signals(
        &self,
        session_id: &str,
    ) -> impl Future<Output = Result<Vec<ExpiredPendingSignalIndexRecord>, CliError>> + Send;
}

impl AsyncSignalReadQueries for AsyncDaemonDb {
    async fn load_signals(&self, session_id: &str) -> Result<Vec<SessionSignalRecord>, CliError> {
        let rows = query_as::<_, AsyncSignalRow>(LOAD_SIGNALS_SQL)
            .bind(session_id)
            .fetch_all(self.pool())
            .await
            .map_err(|error| db_error(format!("query async signals for {session_id}: {error}")))?;
        rows.into_iter().map(AsyncSignalRow::into_record).collect()
    }

    async fn load_agent_activity(
        &self,
        session_id: &str,
    ) -> Result<Vec<AgentToolActivitySummary>, CliError> {
        let rows = query_scalar::<_, String>(LOAD_ACTIVITY_SQL)
            .bind(session_id)
            .fetch_all(self.pool())
            .await
            .map_err(|error| {
                db_error(format!(
                    "query async agent activity for {session_id}: {error}"
                ))
            })?;

        rows.into_iter()
            .map(|json| {
                serde_json::from_str(&json)
                    .map_err(|error| db_error(format!("parse async activity row: {error}")))
            })
            .collect()
    }

    async fn load_expired_pending_signals(
        &self,
        session_id: &str,
    ) -> Result<Vec<ExpiredPendingSignalIndexRecord>, CliError> {
        let rows = query_as::<_, AsyncExpiredPendingSignalRow>(LOAD_EXPIRED_PENDING_SIGNALS_SQL)
            .bind(session_id)
            .fetch_all(self.pool())
            .await
            .map_err(|error| {
                db_error(format!(
                    "query async expired pending signals for {session_id}: {error}"
                ))
            })?;
        let mut signals = Vec::new();
        for row in rows {
            if let Some(record) = row.into_record()? {
                signals.push(record);
            }
        }
        Ok(signals)
    }
}

#[derive(sqlx::FromRow)]
struct AsyncSignalRow {
    signal_json: String,
    ack_json: Option<String>,
    runtime: String,
    agent_id: String,
    session_id: String,
    status: String,
}

impl AsyncSignalRow {
    fn into_record(self) -> Result<SessionSignalRecord, CliError> {
        let signal: Signal = serde_json::from_str(&self.signal_json)
            .map_err(|error| db_error(format!("parse async signal row: {error}")))?;
        let acknowledgment = self
            .ack_json
            .as_deref()
            .and_then(|json| serde_json::from_str(json).ok());
        let stored = match self.status.as_str() {
            "pending" => SessionSignalStatus::Pending,
            "acknowledged" | "delivered" => SessionSignalStatus::Delivered,
            "rejected" => SessionSignalStatus::Rejected,
            "deferred" => SessionSignalStatus::Deferred,
            _ => SessionSignalStatus::Expired,
        };

        Ok(SessionSignalRecord {
            runtime: self.runtime,
            agent_id: self.agent_id,
            session_id: self.session_id,
            status: derive_effective_signal_status(stored, &signal),
            signal,
            acknowledgment,
        })
    }
}

#[derive(sqlx::FromRow)]
struct AsyncExpiredPendingSignalRow {
    signal_json: String,
    runtime: String,
    agent_id: String,
}

impl AsyncExpiredPendingSignalRow {
    fn into_record(self) -> Result<Option<ExpiredPendingSignalIndexRecord>, CliError> {
        let signal: Signal = serde_json::from_str(&self.signal_json).map_err(|error| {
            db_error(format!("parse async expired pending signal row: {error}"))
        })?;
        if derive_effective_signal_status(SessionSignalStatus::Pending, &signal)
            != SessionSignalStatus::Expired
        {
            return Ok(None);
        }
        Ok(Some(ExpiredPendingSignalIndexRecord {
            runtime: self.runtime,
            agent_id: self.agent_id,
            signal,
        }))
    }
}
