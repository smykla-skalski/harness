use sqlx::{Sqlite, Transaction, query};

use super::{AsyncDaemonDb, CliError, SessionSignalRecord, db_error, utc_now};

const DELETE_SIGNAL_INDEX_SQL: &str = "DELETE FROM signal_index WHERE session_id = ?1";
const INSERT_SIGNAL_INDEX_SQL: &str = "
INSERT OR REPLACE INTO signal_index (
    signal_id, session_id, agent_id, runtime, command, priority,
    status, created_at, source_agent, message, action_hint,
    signal_json, ack_json, file_path, indexed_at
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)";

impl AsyncDaemonDb {
    /// Replace one session's signal index from the canonical async daemon DB.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or JSON serialization failures.
    pub(crate) async fn sync_signal_index(
        &self,
        session_id: &str,
        signals: &[SessionSignalRecord],
    ) -> Result<(), CliError> {
        let mut transaction = self.pool().begin().await.map_err(|error| {
            db_error(format!(
                "begin async signal index sync transaction: {error}"
            ))
        })?;
        query(DELETE_SIGNAL_INDEX_SQL)
            .bind(session_id)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("delete async signal index rows: {error}")))?;

        let indexed_at = utc_now();
        for record in signals {
            insert_signal_index_row(&mut transaction, record, &indexed_at).await?;
        }

        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit async signal index sync: {error}")))?;
        Ok(())
    }
}

async fn insert_signal_index_row(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &SessionSignalRecord,
    indexed_at: &str,
) -> Result<(), CliError> {
    let signal_json = serde_json::to_string(&record.signal)
        .map_err(|error| db_error(format!("serialize async signal row: {error}")))?;
    let ack_json = record
        .acknowledgment
        .as_ref()
        .map(serde_json::to_string)
        .transpose()
        .map_err(|error| db_error(format!("serialize async signal acknowledgment: {error}")))?;

    query(INSERT_SIGNAL_INDEX_SQL)
        .bind(&record.signal.signal_id)
        .bind(&record.session_id)
        .bind(&record.agent_id)
        .bind(&record.runtime)
        .bind(&record.signal.command)
        .bind(format!("{:?}", record.signal.priority).to_lowercase())
        .bind(format!("{:?}", record.status).to_lowercase())
        .bind(&record.signal.created_at)
        .bind(&record.signal.source_agent)
        .bind(&record.signal.payload.message)
        .bind(record.signal.payload.action_hint.as_deref())
        .bind(signal_json)
        .bind(ack_json.as_deref())
        .bind("")
        .bind(indexed_at)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("insert async signal index row: {error}")))?;
    Ok(())
}
