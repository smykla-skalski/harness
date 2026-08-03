use chrono::{DateTime, Utc};
use rusqlite::types::Type;

use super::{CliError, Connection, OptionalExtension, db_error};
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_identity::{parse_remote_role, parse_remote_scope};
use crate::daemon::remote_pairing::{RemotePairingCodeHash, RemoteStoredPairing};

pub(crate) mod inventory;
mod metadata;
pub(crate) use metadata::{decode_remote_pairing_metadata, encode_remote_pairing_metadata};

pub(crate) const INSERT_REMOTE_PAIRING_SQL: &str = "
INSERT INTO remote_pairing_codes (
    pairing_id, code_hash, role, scopes_json, created_at, expires_at,
    claimed_at, claimed_client_id, claim_remote_addr, metadata_json
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, NULL, NULL, ?7)";

pub(crate) const SELECT_REMOTE_PAIRING_BY_HASH_SQL: &str = "
SELECT pairing_id, code_hash, role, scopes_json, created_at, expires_at,
       claimed_at, claimed_client_id, claim_remote_addr, metadata_json
FROM remote_pairing_codes
WHERE code_hash = ?1";

pub(crate) const ROUTE_REMOTE_PAIR_CREATE: &str = "remote.pair.create";
pub(crate) const ROUTE_REMOTE_PAIR_CLAIM: &str = "remote.pair.claim";
pub(crate) const ROUTE_REMOTE_PAIR_DOMAIN: &str = "remote.pair.domain";
pub(crate) const ROUTE_REMOTE_PAIR_EXPIRE: &str = "remote.pair.expire";
pub(crate) const ROUTE_REMOTE_PAIR_INVALID: &str = "remote.pair.invalid";
pub(crate) const ROUTE_REMOTE_PAIR_REPLAY: &str = "remote.pair.replay";
pub(crate) const ROUTE_REMOTE_PAIR_UNKNOWN: &str = "remote.pair.unknown";
pub(crate) const ROUTE_REMOTE_PAIR_REVOKED: &str = "remote.pair.revoked";

/// # Errors
/// Returns [`CliError`] on SQL or row parsing failures.
pub(crate) fn load_remote_pairing_by_hash(
    conn: &Connection,
    code_hash: &str,
) -> Result<Option<RemoteStoredPairing>, CliError> {
    conn.query_row(
        SELECT_REMOTE_PAIRING_BY_HASH_SQL,
        [code_hash],
        remote_pairing_from_row,
    )
    .optional()
    .map_err(|error| db_error(format!("load remote pairing by hash: {error}")))
}

fn remote_pairing_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<RemoteStoredPairing> {
    let role_label = row.get::<_, String>(2)?;
    let scopes_json = row.get::<_, String>(3)?;
    let role = parse_remote_role(&role_label).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            2,
            Type::Text,
            format!("unknown remote pairing role '{role_label}'").into(),
        )
    })?;
    let scopes = scopes_from_json(&scopes_json)
        .map_err(|error| rusqlite::Error::FromSqlConversionFailure(3, Type::Text, error.into()))?;
    let code_hash = RemotePairingCodeHash::try_from_storage_value(row.get::<_, String>(1)?)
        .map_err(|error| rusqlite::Error::FromSqlConversionFailure(1, Type::Text, error.into()))?;
    let metadata_json = row.get::<_, String>(9)?;
    let metadata = decode_remote_pairing_metadata(&metadata_json)
        .map_err(|error| rusqlite::Error::FromSqlConversionFailure(9, Type::Text, error.into()))?;
    Ok(RemoteStoredPairing {
        pairing_id: row.get(0)?,
        code_hash,
        role,
        scopes,
        created_at: row.get(4)?,
        expires_at: row.get(5)?,
        claimed_at: row.get(6)?,
        claimed_client_id: row.get(7)?,
        claim_remote_addr: row.get(8)?,
        reviews_query: metadata.reviews_query,
        minted_for: metadata.minted_for,
        minted_by: metadata.minted_by,
        revoked_at: metadata.revoked_at,
    })
}

pub(crate) fn scopes_to_json(scopes: &[RemoteAccessScope]) -> Result<String, CliError> {
    let labels = scopes
        .iter()
        .map(|scope| scope.as_str())
        .collect::<Vec<_>>();
    serde_json::to_string(&labels)
        .map_err(|error| db_error(format!("serialize remote pairing scopes: {error}")))
}

fn scopes_from_json(value: &str) -> Result<Vec<RemoteAccessScope>, String> {
    let labels = serde_json::from_str::<Vec<String>>(value)
        .map_err(|error| format!("parse remote pairing scopes: {error}"))?;
    labels
        .iter()
        .map(|label| {
            parse_remote_scope(label)
                .ok_or_else(|| format!("unknown remote pairing scope '{label}'"))
        })
        .collect()
}

/// # Errors
/// Returns [`CliError`] when either timestamp cannot be parsed.
pub(crate) fn pairing_is_expired(expires_at: &str, now: &str) -> Result<bool, CliError> {
    let expires_at = DateTime::parse_from_rfc3339(expires_at)
        .map_err(|error| db_error(format!("parse remote pairing expiry: {error}")))?
        .with_timezone(&Utc);
    let now = DateTime::parse_from_rfc3339(now)
        .map_err(|error| db_error(format!("parse remote pairing claim time: {error}")))?
        .with_timezone(&Utc);
    Ok(expires_at <= now)
}
