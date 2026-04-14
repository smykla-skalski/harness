use super::{
    CliError, DaemonDb, SessionSignalRecord, SessionSignalStatus, SessionState, Signal, db_error,
    utc_now,
};

#[derive(Debug, Clone)]
pub(crate) struct ExpiredPendingSignalIndexRecord {
    pub(crate) runtime: String,
    pub(crate) agent_id: String,
    pub(crate) signal: Signal,
}

impl DaemonDb {
    /// Sync the signal index for a session from a list of signal records.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn sync_signal_index(
        &self,
        session_id: &str,
        signals: &[SessionSignalRecord],
    ) -> Result<(), CliError> {
        self.conn
            .execute(
                "DELETE FROM signal_index WHERE session_id = ?1",
                [session_id],
            )
            .map_err(|error| db_error(format!("delete signals: {error}")))?;

        let mut statement = self
            .conn
            .prepare(
                "INSERT OR REPLACE INTO signal_index (
                    signal_id, session_id, agent_id, runtime, command, priority,
                    status, created_at, source_agent, message, action_hint,
                    signal_json, ack_json, file_path, indexed_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
            )
            .map_err(|error| db_error(format!("prepare signal insert: {error}")))?;

        let now = utc_now();
        for record in signals {
            let signal_json = serde_json::to_string(&record.signal).unwrap_or_default();
            let ack_json = record
                .acknowledgment
                .as_ref()
                .and_then(|ack| serde_json::to_string(ack).ok());
            let status = format!("{:?}", record.status).to_lowercase();

            statement
                .execute(rusqlite::params![
                    record.signal.signal_id,
                    record.session_id,
                    record.agent_id,
                    record.runtime,
                    record.signal.command,
                    format!("{:?}", record.signal.priority).to_lowercase(),
                    status,
                    record.signal.created_at,
                    record.signal.source_agent,
                    record.signal.payload.message,
                    record.signal.payload.action_hint,
                    signal_json,
                    ack_json,
                    "",
                    now,
                ])
                .map_err(|error| db_error(format!("insert signal: {error}")))?;
        }
        Ok(())
    }

    /// Load signals for a session from the index.
    ///
    /// Pending signals whose `expires_at` has passed are surfaced as
    /// `Expired` at read time so every caller sees a correct status without
    /// a background sweeper or a schema change. Signals keep their stored
    /// status once an ack has been written, so delivered/rejected/deferred
    /// rows pass through unchanged.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn load_signals(&self, session_id: &str) -> Result<Vec<SessionSignalRecord>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT signal_json, ack_json, runtime, agent_id, session_id, status
                 FROM signal_index WHERE session_id = ?1
                 ORDER BY created_at DESC",
            )
            .map_err(|error| db_error(format!("prepare signal load: {error}")))?;

        let rows = statement
            .query_map([session_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                ))
            })
            .map_err(|error| db_error(format!("query signals: {error}")))?;

        let mut signals = Vec::new();
        for row in rows {
            let (signal_json, ack_json, runtime, agent_id, sid, status_str) =
                row.map_err(|error| db_error(format!("read signal row: {error}")))?;
            let signal: Signal = serde_json::from_str(&signal_json)
                .map_err(|error| db_error(format!("parse signal: {error}")))?;
            let acknowledgment = ack_json
                .as_deref()
                .and_then(|json| serde_json::from_str(json).ok());
            let stored = match status_str.as_str() {
                "pending" => SessionSignalStatus::Pending,
                "acknowledged" | "delivered" => SessionSignalStatus::Delivered,
                "rejected" => SessionSignalStatus::Rejected,
                "deferred" => SessionSignalStatus::Deferred,
                _ => SessionSignalStatus::Expired,
            };
            let status = derive_effective_signal_status(stored, &signal);
            signals.push(SessionSignalRecord {
                runtime,
                agent_id,
                session_id: sid,
                status,
                signal,
                acknowledgment,
            });
        }
        Ok(signals)
    }

    /// Load only pending signals whose expiry has already passed.
    ///
    /// This keeps callers on the indexed fast path for the common case where a
    /// session has no expired pending deliveries to reconcile.
    ///
    /// # Errors
    /// Returns [`CliError`] on query or JSON parse failure.
    pub(crate) fn load_expired_pending_signals(
        &self,
        session_id: &str,
    ) -> Result<Vec<ExpiredPendingSignalIndexRecord>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT signal_json, runtime, agent_id
                 FROM signal_index
                 WHERE session_id = ?1 AND status = 'pending'
                 ORDER BY created_at DESC",
            )
            .map_err(|error| db_error(format!("prepare expired pending signal load: {error}")))?;

        let rows = statement
            .query_map([session_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })
            .map_err(|error| db_error(format!("query expired pending signals: {error}")))?;

        let mut signals = Vec::new();
        for row in rows {
            let (signal_json, runtime, agent_id) =
                row.map_err(|error| db_error(format!("read expired pending signal row: {error}")))?;
            let signal: Signal = serde_json::from_str(&signal_json)
                .map_err(|error| db_error(format!("parse expired pending signal: {error}")))?;
            if derive_effective_signal_status(SessionSignalStatus::Pending, &signal)
                == SessionSignalStatus::Expired
            {
                signals.push(ExpiredPendingSignalIndexRecord {
                    runtime,
                    agent_id,
                    signal,
                });
            }
        }

        Ok(signals)
    }

    /// Whether any agent in the session shares a runtime session ID with a
    /// different orchestration session.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn session_has_shared_runtime_signal_dir(
        &self,
        state: &SessionState,
    ) -> Result<bool, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT COUNT(DISTINCT session_id)
                 FROM agents
                 WHERE runtime = ?1 AND agent_session_id = ?2",
            )
            .map_err(|error| db_error(format!("prepare shared runtime lookup: {error}")))?;

        for agent in state.agents.values() {
            let Some(agent_session_id) = agent.agent_session_id.as_deref() else {
                continue;
            };

            let count: i64 = statement
                .query_row(rusqlite::params![agent.runtime, agent_session_id], |row| {
                    row.get(0)
                })
                .map_err(|error| db_error(format!("query shared runtime lookup: {error}")))?;
            if count > 1 {
                return Ok(true);
            }
        }

        Ok(false)
    }
}

pub(super) fn derive_effective_signal_status(
    stored: SessionSignalStatus,
    signal: &Signal,
) -> SessionSignalStatus {
    if stored != SessionSignalStatus::Pending {
        return stored;
    }
    match chrono::DateTime::parse_from_rfc3339(&signal.expires_at) {
        Ok(expires_at) if expires_at < chrono::Utc::now() => SessionSignalStatus::Expired,
        _ => stored,
    }
}
