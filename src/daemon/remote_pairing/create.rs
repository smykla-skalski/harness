//! The one path that turns a request for a pairing link into a stored record
//! and an invitation.
//!
//! The CLI and the mint route both land here, so a link handed out over HTTP
//! carries exactly the role, scope, expiry, and invitation payload that a link
//! created on the host does. Anything that must differ between the two - who
//! may ask, and what the caller is allowed to see afterwards - is decided by
//! the caller, not here.

use chrono::{DateTime, Duration as ChronoDuration, Utc};

use super::invitation::build_remote_pairing_invitation;
use super::subject::RemotePairingSubject;
use super::{RemotePairingCode, RemotePairingRecord};
use crate::daemon::db::DaemonDb;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::RemoteAuditEvent;
use harness_kernel::errors::{CliError, CliErrorKind};
use crate::reviews::ReviewsQueryRequest;

/// Resolve a pairing expiry from its creation time and TTL.
///
/// # Errors
/// Returns [`CliError`] when `created_at` is not RFC 3339 or the TTL pushes the
/// expiry past what a timestamp can hold.
pub(crate) fn pairing_expires_at(created_at: &str, ttl_seconds: u64) -> Result<String, CliError> {
    let created_at = DateTime::parse_from_rfc3339(created_at)
        .map_err(|error| CliErrorKind::workflow_parse(format!("parse pairing time: {error}")))?
        .with_timezone(&Utc);
    let ttl_seconds = i64::try_from(ttl_seconds)
        .map_err(|_| CliErrorKind::workflow_parse("pairing ttl value is too large"))?;
    let expires_at = created_at
        .checked_add_signed(ChronoDuration::seconds(ttl_seconds))
        .ok_or_else(|| CliErrorKind::workflow_parse("pairing ttl value is too large"))?;
    Ok(expires_at.format("%Y-%m-%dT%H:%M:%SZ").to_string())
}

pub(crate) struct RemotePairingCreateParams<'a> {
    pub pairing_id: &'a str,
    pub audit_event_id: &'a str,
    pub code: &'a RemotePairingCode,
    pub created_at: &'a str,
    pub expires_at: &'a str,
    pub ttl_seconds: u64,
    pub role: RemoteRole,
    pub requested_scopes: &'a [RemoteAccessScope],
    pub reviews_query: Option<&'a ReviewsQueryRequest>,
    pub minted_for: Option<&'a RemotePairingSubject>,
    /// The client doing the minting, so a later caller can be shown the links
    /// it is responsible for and no others. `None` for a link created on the
    /// host, which belongs to whoever has access to the host.
    pub minted_by: Option<&'a str>,
    /// Written in the same transaction as the pairing row, so a caller never
    /// ends up with a committed link whose audit trail failed to record.
    pub extra_audit: Option<&'a RemoteAuditEvent>,
}

pub(crate) struct RemotePairingCreated {
    pub pairing_id: String,
    pub role: String,
    pub scopes: Vec<String>,
    pub created_at: String,
    pub expires_at: String,
    pub ttl_seconds: u64,
    pub endpoint: String,
    pub server_spki_sha256: String,
    pub pairing_url: String,
    pub reviews_query: Option<ReviewsQueryRequest>,
}

/// Persist a pairing record and build its invitation.
///
/// The raw code is never returned here. It is already inside the invitation
/// payload, and the caller that generated it still holds it, so handing back a
/// second copy would only widen where it can be logged.
///
/// # Errors
/// Returns [`CliError`] when scope expansion, subject validation, invitation
/// assembly, or persistence fails.
pub(crate) fn create_remote_pairing(
    db: &DaemonDb,
    params: &RemotePairingCreateParams<'_>,
) -> Result<RemotePairingCreated, CliError> {
    if let Some(subject) = params.minted_for {
        subject
            .validate()
            .map_err(|error| CliErrorKind::workflow_parse(error.to_string()))?;
    }
    let record = RemotePairingRecord::new_with_reviews_query(
        params.pairing_id,
        params.role,
        params.requested_scopes,
        params.code.expose(),
        params.created_at,
        params.expires_at,
        params.reviews_query,
    )
    .map_err(|error| CliErrorKind::workflow_parse(error.to_string()))?
    .minted_for(params.minted_for.cloned())
    .minted_by(params.minted_by.map(str::to_owned));
    let role = record.role.as_str().to_owned();
    let scopes = record
        .scopes
        .iter()
        .map(|scope| scope.as_str().to_owned())
        .collect::<Vec<_>>();
    let invitation = build_remote_pairing_invitation(
        db,
        params.code.expose(),
        role.as_str(),
        &scopes,
        record.expires_at.as_str(),
    )?;
    let stored = db.create_remote_pairing_code_with_audit(
        &record,
        params.audit_event_id,
        params.extra_audit,
    )?;
    Ok(RemotePairingCreated {
        pairing_id: stored.pairing_id,
        role,
        scopes,
        created_at: stored.created_at,
        expires_at: stored.expires_at,
        ttl_seconds: params.ttl_seconds,
        endpoint: invitation.endpoint,
        server_spki_sha256: invitation.server_spki_sha256,
        pairing_url: invitation.pairing_url,
        reviews_query: stored.reviews_query,
    })
}
