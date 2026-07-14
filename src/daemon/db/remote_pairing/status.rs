use rusqlite::OptionalExtension as _;

use super::{DaemonDb, db_error, pairing_is_expired};
use crate::daemon::remote_pairing::RemotePairingStatus;
use crate::errors::CliError;

const SELECT_REMOTE_PAIRING_STATUS_SQL: &str = "
SELECT expires_at, claimed_at
FROM remote_pairing_codes
WHERE pairing_id = ?1";

impl DaemonDb {
    /// Load the public lifecycle state for an opaque remote pairing id.
    ///
    /// Unknown and blank ids collapse to `unavailable` so the public endpoint
    /// does not expose whether arbitrary input resembles a stored record.
    ///
    /// # Errors
    /// Returns [`CliError`] when the status row or timestamp cannot be read.
    pub(crate) fn load_remote_pairing_status(
        &self,
        pairing_id: &str,
        now: &str,
    ) -> Result<RemotePairingStatus, CliError> {
        let pairing_id = pairing_id.trim();
        if pairing_id.is_empty() {
            return Ok(RemotePairingStatus::Unavailable);
        }
        let row = self
            .conn
            .query_row(SELECT_REMOTE_PAIRING_STATUS_SQL, [pairing_id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
            })
            .optional()
            .map_err(|error| db_error(format!("load remote pairing status: {error}")))?;
        let Some((expires_at, claimed_at)) = row else {
            return Ok(RemotePairingStatus::Unavailable);
        };
        if claimed_at.is_some() {
            return Ok(RemotePairingStatus::Claimed);
        }
        if pairing_is_expired(&expires_at, now)? {
            self.record_remote_pairing_expiration(pairing_id, now)?;
            return Ok(RemotePairingStatus::Expired);
        }
        Ok(RemotePairingStatus::Pending)
    }
}
