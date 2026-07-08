use rusqlite::{OptionalExtension, params, types::Type};

use super::{CliError, DaemonDb, db_error};
use crate::daemon::remote_acme::RemoteRenewalOutcome;

const SELECT_REMOTE_ACME_STATE_SQL: &str = "
SELECT
    NULLIF(TRIM(account_id), ''),
    CASE WHEN COALESCE(TRIM(account_id), '') <> '' THEN 1 ELSE 0 END,
    CASE
        WHEN COALESCE(TRIM(certificate_pem), '') <> ''
         AND COALESCE(TRIM(private_key_pem), '') <> ''
         AND COALESCE(TRIM(certificate_fingerprint), '') <> ''
        THEN 1 ELSE 0
    END,
    NULLIF(TRIM(certificate_fingerprint), ''),
    renewal_status,
    renewal_error,
    updated_at
FROM remote_acme_state
WHERE singleton = 1";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemoteAcmeRenewalStatus {
    Unknown,
    Succeeded,
    Failed,
}

impl RemoteAcmeRenewalStatus {
    #[must_use]
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RemoteAcmeStoredState {
    pub(crate) account_configured: bool,
    pub(crate) account_id: Option<String>,
    pub(crate) certificate_configured: bool,
    pub(crate) certificate_fingerprint: Option<String>,
    pub(crate) renewal_status: RemoteAcmeRenewalStatus,
    pub(crate) renewal_error: Option<String>,
    pub(crate) updated_at: String,
}

impl DaemonDb {
    /// Load token-safe remote ACME status from the singleton state row.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or status parsing failures.
    pub(crate) fn load_remote_acme_state(&self) -> Result<RemoteAcmeStoredState, CliError> {
        self.conn
            .query_row(SELECT_REMOTE_ACME_STATE_SQL, [], remote_acme_state_from_row)
            .optional()
            .map_err(|error| db_error(format!("load remote acme state: {error}")))?
            .ok_or_else(|| db_error("remote acme singleton state row is missing"))
    }

    /// Persist a redacted ACME renewal failure report.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    pub(crate) fn record_remote_acme_renewal_failure(
        &self,
        detail: &str,
        updated_at: &str,
    ) -> Result<(), CliError> {
        let report = RemoteRenewalOutcome::failure(detail).report().to_string();
        self.conn
            .execute(
                "INSERT INTO remote_acme_state (
                     singleton, renewal_status, renewal_error, updated_at
                 ) VALUES (1, 'failed', ?1, ?2)
                 ON CONFLICT(singleton) DO UPDATE SET
                     renewal_status = excluded.renewal_status,
                     renewal_error = excluded.renewal_error,
                     updated_at = excluded.updated_at",
                params![report, updated_at],
            )
            .map_err(|error| db_error(format!("record remote acme renewal failure: {error}")))?;
        Ok(())
    }
}

fn remote_acme_state_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<RemoteAcmeStoredState> {
    let status_label = row.get::<_, String>(4)?;
    Ok(RemoteAcmeStoredState {
        account_id: row.get(0)?,
        account_configured: row.get::<_, i64>(1)? != 0,
        certificate_configured: row.get::<_, i64>(2)? != 0,
        certificate_fingerprint: row.get(3)?,
        renewal_status: parse_renewal_status_at_column(&status_label, 4)?,
        renewal_error: row.get(5)?,
        updated_at: row.get(6)?,
    })
}

fn parse_renewal_status_at_column(
    label: &str,
    column: usize,
) -> rusqlite::Result<RemoteAcmeRenewalStatus> {
    match label {
        "unknown" => Ok(RemoteAcmeRenewalStatus::Unknown),
        "succeeded" => Ok(RemoteAcmeRenewalStatus::Succeeded),
        "failed" => Ok(RemoteAcmeRenewalStatus::Failed),
        _ => Err(rusqlite::Error::FromSqlConversionFailure(
            column,
            Type::Text,
            format!("unknown remote acme renewal status '{label}'").into(),
        )),
    }
}
