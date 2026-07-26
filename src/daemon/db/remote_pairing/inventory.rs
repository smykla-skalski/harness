//! Enumerating pairings and the devices they became.

use rusqlite::Row;

use super::{DaemonDb, db_error, decode_remote_pairing_metadata, pairing_is_expired};
use crate::daemon::remote_pairing::{
    RemotePairingDevice, RemotePairingInventoryEntry, RemotePairingObservation, RemotePairingState,
};
use harness_kernel::errors::CliError;

/// The join is a LEFT one because an unclaimed link has no device yet, and an
/// inner join would silently drop exactly the pending and expired rows the
/// caller most wants to see.
const SELECT_REMOTE_PAIRING_INVENTORY_SQL: &str = "
SELECT p.pairing_id,
       p.role,
       p.created_at,
       p.expires_at,
       p.claimed_at,
       p.metadata_json,
       c.client_id,
       c.display_name,
       c.platform,
       c.last_seen_at,
       c.revoked_at
FROM remote_pairing_codes p
LEFT JOIN remote_clients c ON c.client_id = p.claimed_client_id
ORDER BY p.created_at DESC, p.pairing_id DESC";

impl DaemonDb {
    /// Every pairing, newest first, with the device each one became.
    ///
    /// Ownership is not filtered here. The caller decides what it is entitled
    /// to see, because that depends on scopes this layer does not know about.
    ///
    /// # Errors
    /// Returns [`CliError`] when a row or its metadata cannot be read.
    pub(crate) fn list_remote_pairing_inventory(
        &self,
        now: &str,
    ) -> Result<Vec<RemotePairingInventoryEntry>, CliError> {
        let mut statement = self
            .conn
            .prepare(SELECT_REMOTE_PAIRING_INVENTORY_SQL)
            .map_err(|error| db_error(format!("prepare remote pairing inventory: {error}")))?;
        let rows = statement
            .query_map([], |row| Ok(read_inventory_columns(row)))
            .map_err(|error| db_error(format!("query remote pairing inventory: {error}")))?;

        let mut entries = Vec::new();
        for row in rows {
            let columns = row
                .map_err(|error| db_error(format!("read remote pairing inventory: {error}")))??;
            entries.push(entry_from_columns(columns, now)?);
        }
        Ok(entries)
    }
}

struct InventoryColumns {
    pairing_id: String,
    role: String,
    created_at: String,
    expires_at: String,
    claimed_at: Option<String>,
    metadata_json: String,
    client_id: Option<String>,
    display_name: Option<String>,
    platform: Option<String>,
    last_seen_at: Option<String>,
    revoked_at: Option<String>,
}

fn read_inventory_columns(row: &Row<'_>) -> Result<InventoryColumns, CliError> {
    let column = |index: usize| -> Result<String, CliError> {
        row.get::<_, String>(index)
            .map_err(|error| db_error(format!("read remote pairing inventory column: {error}")))
    };
    let optional = |index: usize| -> Result<Option<String>, CliError> {
        row.get::<_, Option<String>>(index)
            .map_err(|error| db_error(format!("read remote pairing inventory column: {error}")))
    };
    Ok(InventoryColumns {
        pairing_id: column(0)?,
        role: column(1)?,
        created_at: column(2)?,
        expires_at: column(3)?,
        claimed_at: optional(4)?,
        metadata_json: column(5)?,
        client_id: optional(6)?,
        display_name: optional(7)?,
        platform: optional(8)?,
        last_seen_at: optional(9)?,
        revoked_at: optional(10)?,
    })
}

fn entry_from_columns(
    columns: InventoryColumns,
    now: &str,
) -> Result<RemotePairingInventoryEntry, CliError> {
    let metadata = decode_remote_pairing_metadata(&columns.metadata_json)
        .map_err(|error| db_error(format!("read remote pairing inventory metadata: {error}")))?;
    let expired = pairing_is_expired(&columns.expires_at, now)?;
    // Either end can carry the revocation: a claimed link is cut off through
    // the device it became, while one withdrawn before any claim has no device
    // and is marked on the pairing itself. Reading only the device would show a
    // withdrawn link as pending until it happened to expire.
    let revoked_at = metadata
        .revoked_at
        .as_deref()
        .or(columns.revoked_at.as_deref());
    let state = RemotePairingState::derive(&RemotePairingObservation {
        claimed_at: columns.claimed_at.as_deref(),
        revoked_at,
        last_seen_at: columns.last_seen_at.as_deref(),
        expired,
    });

    // The device is built from the joined columns only when the join matched.
    // Reading them individually would invent a device out of a row where every
    // column is null.
    let device = columns.client_id.map(|client_id| RemotePairingDevice {
        client_id,
        display_name: columns.display_name.unwrap_or_default(),
        platform: columns.platform.unwrap_or_default(),
        last_seen_at: columns.last_seen_at,
        revoked_at: columns.revoked_at,
    });

    Ok(RemotePairingInventoryEntry {
        pairing_id: columns.pairing_id,
        state: state.as_str().to_owned(),
        role: columns.role,
        created_at: columns.created_at,
        expires_at: columns.expires_at,
        claimed_at: columns.claimed_at,
        minted_for: metadata.minted_for,
        minted_by: metadata.minted_by,
        device,
    })
}
