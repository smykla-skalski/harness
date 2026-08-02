//! `db`'s interface onto [`DaemonDb`] and [`AsyncDaemonDb`] for remote pairing
//! codes, the inventory built from them, and their lifecycle.
//!
//! `db/remote_pairing.rs`, `db/remote_pairing/inventory.rs`, and
//! `db/remote_pairing_revoke.rs` keep this area's SQL and row parsing, but
//! the traits and their impls live here, next to the domain code that calls
//! them (`daemon::http::remote_pairing`, `harness-daemon-remote-cli`) rather
//! than inside `db`. `db` doesn't own either type's callers, and an inherent
//! `impl` block for this area could never move into a crate `db` doesn't
//! share with them; a trait this module declares has no such problem, since
//! Rust's orphan rule only needs one of the trait or the implementing type to
//! be local. `RemotePairingClaimCodeError`, `RemotePairingOwner`,
//! `RemotePairingRevoked`, and `RemotePairingRevokeOutcome` moved here too,
//! for the same reason: a type a trait's signature returns has to live
//! somewhere that stays reachable without reaching into `db`.
//!
//! Two traits, not one, because `DaemonDb` and `AsyncDaemonDb` are different
//! concrete types with disjoint method sets here: revoking a pairing and
//! sweeping expirations are async-only, everything else is sync-only. Each
//! impl lives in its own submodule so this file stays the trait/type
//! declarations only.

use std::error::Error;
use std::fmt;

use harness_kernel::errors::CliError;

use super::remote_identity::RemoteAuditEvent;
use super::remote_pairing::{
    RemotePairingClaimRequest, RemotePairingClaimedClient, RemotePairingError,
    RemotePairingInventoryEntry, RemotePairingRecord, RemotePairingStatus, RemoteStoredPairing,
};

mod async_impl;
mod sync_impl;

/// Who a pairing belongs to.
///
/// Three cases rather than a nested option, because "no such pairing" and
/// "created on the host" are different answers and a caller that conflated
/// them would treat an operator's link as one it may revoke.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RemotePairingOwner {
    Unknown,
    /// Created on the host, so no remote client owns it.
    Host,
    /// Minted by this client.
    Client(String),
}

#[derive(Debug)]
pub(crate) enum RemotePairingClaimCodeError {
    Pairing(RemotePairingError),
    Store(CliError),
}

impl RemotePairingClaimCodeError {
    fn pairing(error: RemotePairingError) -> Self {
        Self::Pairing(error)
    }

    fn store(error: CliError) -> Self {
        Self::Store(error)
    }
}

impl fmt::Display for RemotePairingClaimCodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Pairing(error) => write!(f, "{error}"),
            Self::Store(error) => write!(f, "{error}"),
        }
    }
}

impl Error for RemotePairingClaimCodeError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Pairing(error) => Some(error),
            Self::Store(error) => Some(error),
        }
    }
}

/// What revoking did, and when the revocation it reports actually happened.
///
/// The timestamp is not always the request time: a second revoke reports the
/// moment the device was really cut off, because a caller retrying otherwise
/// cannot tell its own attempt apart from the one that did the work.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RemotePairingRevoked {
    pub outcome: RemotePairingRevokeOutcome,
    pub revoked_at: String,
}

/// What revoking found to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemotePairingRevokeOutcome {
    /// The device that claimed this link can no longer reach the daemon.
    DeviceRevoked,
    /// Nobody had claimed it, and now nobody can.
    LinkWithdrawn,
    /// Already revoked, by this route or by a client revoking itself.
    AlreadyRevoked,
    /// No such pairing.
    NotFound,
}

/// The sync half, backed by [`DaemonDb`](crate::daemon::db::DaemonDb).
pub(crate) trait RemotePairingQueries {
    /// # Errors
    /// Returns [`CliError`] on SQL or scope serialization failures.
    #[cfg_attr(
        not(test),
        allow(
            dead_code,
            reason = "convenience wrapper exercised only by tests today"
        )
    )]
    fn create_remote_pairing_code(
        &self,
        record: &RemotePairingRecord,
        audit_event_id: &str,
    ) -> Result<RemoteStoredPairing, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL or scope serialization failures.
    fn create_remote_pairing_code_with_audit(
        &self,
        record: &RemotePairingRecord,
        audit_event_id: &str,
        extra_audit: Option<&RemoteAuditEvent>,
    ) -> Result<RemoteStoredPairing, CliError>;

    /// # Errors
    /// Returns [`RemotePairingClaimCodeError`] when the claim is invalid,
    /// expired, already used, or persistence fails.
    fn claim_remote_pairing_code(
        &self,
        code: &str,
        claim: &RemotePairingClaimRequest,
        now: &str,
    ) -> Result<RemotePairingClaimedClient, RemotePairingClaimCodeError>;

    /// # Errors
    /// Returns [`CliError`] when the row or its metadata cannot be read.
    fn remote_pairing_minted_by(&self, pairing_id: &str) -> Result<RemotePairingOwner, CliError>;

    /// # Errors
    /// Returns [`CliError`] when a row or its metadata cannot be read.
    fn list_remote_pairing_inventory(
        &self,
        now: &str,
        minted_by: Option<&str>,
    ) -> Result<Vec<RemotePairingInventoryEntry>, CliError>;

    /// # Errors
    /// Returns [`CliError`] when the query fails.
    fn remote_pairing_claimed_by(&self, client_id: &str) -> Result<Option<String>, CliError>;

    /// # Errors
    /// Returns [`CliError`] when the row or its metadata cannot be read.
    fn remote_pairing_inventory_entry(
        &self,
        pairing_id: &str,
        now: &str,
    ) -> Result<Option<RemotePairingInventoryEntry>, CliError>;

    /// # Errors
    /// Returns [`CliError`] when the status row or timestamp cannot be read.
    fn load_remote_pairing_status(
        &self,
        pairing_id: &str,
        now: &str,
    ) -> Result<RemotePairingStatus, CliError>;

    /// # Errors
    /// Returns [`CliError`] when the expiration audit cannot be persisted.
    fn record_remote_pairing_expiration(
        &self,
        pairing_id: &str,
        now: &str,
    ) -> Result<bool, CliError>;
}

/// The async half, backed by [`AsyncDaemonDb`](crate::daemon::db::AsyncDaemonDb).
pub(crate) trait RemotePairingAsyncQueries: Send + Sync {
    /// # Errors
    /// Returns [`CliError`] when the expiration sweep cannot be persisted.
    async fn record_expired_remote_pairings(&self, now: &str) -> Result<u64, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    async fn revoke_remote_pairing_with_audit(
        &self,
        pairing_id: &str,
        revoked_at: &str,
        audit: &RemoteAuditEvent,
    ) -> Result<RemotePairingRevoked, CliError>;
}
