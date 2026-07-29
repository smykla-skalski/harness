//! `db`'s interface onto [`DaemonDb`] and [`AsyncDaemonDb`] for remote client
//! identity, tokens, and their audit trail.
//!
//! `db/remote_identity.rs` (sync) and `db/remote_identity_async.rs` (async)
//! persist this area's state, but the traits live here, next to the domain
//! code that calls them (`daemon::http::auth`, `daemon::websocket::connection`,
//! `daemon::transport::remote_clients`) rather than inside `db`. `db` doesn't
//! own either type's callers, and an inherent `impl` block for this area could
//! never move into a crate `db` doesn't share with them; a trait this module
//! declares has no such problem, since Rust's orphan rule only needs one of
//! the trait or the implementing type to be local.
//!
//! Two traits, not one, because `DaemonDb` and `AsyncDaemonDb` are different
//! concrete types with disjoint method sets here: `DaemonDb` never persists
//! [`revoke_remote_client_with_audit`](RemoteIdentityQueries::revoke_remote_client_with_audit)'s
//! atomic revoke-plus-audit, and `AsyncDaemonDb` never registers or lists
//! clients synchronously.

use harness_kernel::errors::CliError;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};

use super::remote_identity::{
    RemoteAuditEvent, RemoteClientRegistration, RemoteStoredAuditEvent, RemoteStoredClient,
};

/// The async half, backed by [`AsyncDaemonDb`].
#[allow(
    dead_code,
    reason = "the crate-boundary seam this module exists for; every caller \
              still goes through the inherent method each one forwards to"
)]
pub(crate) trait RemoteIdentityQueries: Send + Sync {
    /// # Errors
    /// Returns [`CliError`] on SQL failure or an audit/client identity mismatch.
    async fn revoke_remote_client_with_audit(
        &self,
        client_id: &str,
        revoked_at: &str,
        audit: &RemoteAuditEvent,
    ) -> Result<bool, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    async fn record_remote_audit_event(&self, event: &RemoteAuditEvent) -> Result<(), CliError>;

    /// # Errors
    /// Returns [`CliError`] when the retention transaction cannot complete.
    async fn prune_remote_audit_events(&self) -> Result<u64, CliError>;

    /// # Errors
    /// Returns [`CliError`] when the row is missing, denied, or cannot be updated.
    async fn mark_remote_audit_event_failed(
        &self,
        event_id: &str,
        error_detail: &str,
    ) -> Result<(), CliError>;
}

/// The sync half, backed by [`DaemonDb`].
#[allow(
    dead_code,
    reason = "the crate-boundary seam this module exists for; every caller \
              still goes through the inherent method each one forwards to"
)]
pub(crate) trait RemoteIdentitySyncQueries {
    /// # Errors
    /// Returns [`CliError`] on SQL or scope serialization failures.
    fn register_remote_client(
        &self,
        registration: &RemoteClientRegistration,
    ) -> Result<RemoteStoredClient, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL or row parsing failures.
    fn list_remote_clients(&self) -> Result<Vec<RemoteStoredClient>, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL or row parsing failures.
    fn verify_remote_client_token(
        &self,
        client_id: &str,
        token: &str,
    ) -> Result<Option<RemoteStoredClient>, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL or row parsing failures.
    fn validate_remote_client_session(
        &self,
        authenticated: &RemoteStoredClient,
    ) -> Result<Option<RemoteStoredClient>, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    fn revoke_remote_client(&self, client_id: &str, revoked_at: &str) -> Result<bool, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    fn rotate_remote_client_token(
        &self,
        client_id: &str,
        token: &str,
        rotated_at: &str,
    ) -> Result<bool, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    fn record_remote_audit_event(&self, event: &RemoteAuditEvent) -> Result<(), CliError>;

    /// # Errors
    /// Returns [`CliError`] when the retention transaction cannot complete.
    fn prune_remote_audit_events(&self) -> Result<u64, CliError>;

    /// # Errors
    /// Returns [`CliError`] when the row is missing, denied, or cannot be updated.
    fn mark_remote_audit_event_failed(
        &self,
        event_id: &str,
        error_detail: &str,
    ) -> Result<(), CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL or row parsing failures.
    fn load_remote_audit_events(&self, limit: u32)
    -> Result<Vec<RemoteStoredAuditEvent>, CliError>;
}

/// The async trait's one and only impl for [`AsyncDaemonDb`]. Every method is
/// a thin forward into the matching inherent method
/// (`db/remote_identity_async.rs`), kept on `Self` so nothing outside `db`
/// has to change to keep calling them by the same name.
impl RemoteIdentityQueries for AsyncDaemonDb {
    async fn revoke_remote_client_with_audit(
        &self,
        client_id: &str,
        revoked_at: &str,
        audit: &RemoteAuditEvent,
    ) -> Result<bool, CliError> {
        Self::revoke_remote_client_with_audit(self, client_id, revoked_at, audit).await
    }

    async fn record_remote_audit_event(&self, event: &RemoteAuditEvent) -> Result<(), CliError> {
        Self::record_remote_audit_event(self, event).await
    }

    async fn prune_remote_audit_events(&self) -> Result<u64, CliError> {
        Self::prune_remote_audit_events(self).await
    }

    async fn mark_remote_audit_event_failed(
        &self,
        event_id: &str,
        error_detail: &str,
    ) -> Result<(), CliError> {
        Self::mark_remote_audit_event_failed(self, event_id, error_detail).await
    }
}

/// The sync trait's one and only impl for [`DaemonDb`]. Every method is a
/// thin forward into the matching inherent method (`db/remote_identity.rs`),
/// kept on `Self` so nothing outside `db` has to change to keep calling them
/// by the same name.
impl RemoteIdentitySyncQueries for DaemonDb {
    fn register_remote_client(
        &self,
        registration: &RemoteClientRegistration,
    ) -> Result<RemoteStoredClient, CliError> {
        Self::register_remote_client(self, registration)
    }

    fn list_remote_clients(&self) -> Result<Vec<RemoteStoredClient>, CliError> {
        Self::list_remote_clients(self)
    }

    fn verify_remote_client_token(
        &self,
        client_id: &str,
        token: &str,
    ) -> Result<Option<RemoteStoredClient>, CliError> {
        Self::verify_remote_client_token(self, client_id, token)
    }

    fn validate_remote_client_session(
        &self,
        authenticated: &RemoteStoredClient,
    ) -> Result<Option<RemoteStoredClient>, CliError> {
        Self::validate_remote_client_session(self, authenticated)
    }

    fn revoke_remote_client(&self, client_id: &str, revoked_at: &str) -> Result<bool, CliError> {
        Self::revoke_remote_client(self, client_id, revoked_at)
    }

    fn rotate_remote_client_token(
        &self,
        client_id: &str,
        token: &str,
        rotated_at: &str,
    ) -> Result<bool, CliError> {
        Self::rotate_remote_client_token(self, client_id, token, rotated_at)
    }

    fn record_remote_audit_event(&self, event: &RemoteAuditEvent) -> Result<(), CliError> {
        Self::record_remote_audit_event(self, event)
    }

    fn prune_remote_audit_events(&self) -> Result<u64, CliError> {
        Self::prune_remote_audit_events(self)
    }

    fn mark_remote_audit_event_failed(
        &self,
        event_id: &str,
        error_detail: &str,
    ) -> Result<(), CliError> {
        Self::mark_remote_audit_event_failed(self, event_id, error_detail)
    }

    fn load_remote_audit_events(
        &self,
        limit: u32,
    ) -> Result<Vec<RemoteStoredAuditEvent>, CliError> {
        Self::load_remote_audit_events(self, limit)
    }
}
