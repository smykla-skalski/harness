use std::borrow::Cow;
use std::sync::{Arc, Mutex};

use uuid::Uuid;

use super::db::DaemonDb;
use super::remote::RemoteAccessScope;
use super::remote_identity::{RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision};
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

const REMOTE_AUDIT_REQUEST_ID_MAX_BYTES: usize = 256;
const REMOTE_AUDIT_TRUNCATION_MARKER: &str = "...";

pub(crate) struct RemoteAuthorizationAudit<'a> {
    request_id: &'a str,
    client_id: Option<&'a str>,
    target: &'a str,
    scope: RemoteAccessScope,
    decision: RemoteAuditScopeDecision,
    outcome: RemoteAuditOutcome,
    remote_addr: Option<&'a str>,
    error_detail: Option<&'a str>,
}

impl<'a> RemoteAuthorizationAudit<'a> {
    pub(crate) fn allowed(
        request_id: &'a str,
        client_id: &'a str,
        target: &'a str,
        scope: RemoteAccessScope,
        remote_addr: Option<&'a str>,
    ) -> Self {
        Self {
            request_id,
            client_id: Some(client_id),
            target,
            scope,
            decision: RemoteAuditScopeDecision::Allowed,
            outcome: RemoteAuditOutcome::Success,
            remote_addr,
            error_detail: None,
        }
    }

    pub(crate) fn allowed_failure(
        request_id: &'a str,
        client_id: &'a str,
        target: &'a str,
        scope: RemoteAccessScope,
        remote_addr: Option<&'a str>,
        error_detail: &'a str,
    ) -> Self {
        Self {
            request_id,
            client_id: Some(client_id),
            target,
            scope,
            decision: RemoteAuditScopeDecision::Allowed,
            outcome: RemoteAuditOutcome::Failure,
            remote_addr,
            error_detail: Some(error_detail),
        }
    }

    pub(crate) fn denied(
        request_id: &'a str,
        client_id: Option<&'a str>,
        target: &'a str,
        scope: RemoteAccessScope,
        remote_addr: Option<&'a str>,
        error_detail: &'a str,
    ) -> Self {
        Self {
            request_id,
            client_id,
            target,
            scope,
            decision: RemoteAuditScopeDecision::Denied,
            outcome: RemoteAuditOutcome::Failure,
            remote_addr,
            error_detail: Some(error_detail),
        }
    }

    /// Persist the authorization decision before the request reaches its handler.
    ///
    /// # Errors
    /// Returns [`CliError`] when the audit store is unavailable or rejects the event.
    pub(crate) fn record(self, db: Option<&Arc<Mutex<DaemonDb>>>) -> Result<(), CliError> {
        let db = db.ok_or_else(|| {
            CliError::from(CliErrorKind::workflow_io(
                "remote authorization audit store is unavailable",
            ))
        })?;
        let db = db.lock().map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "remote authorization audit store lock: {error}"
            )))
        })?;
        let request_id = bounded_request_id(self.request_id);
        db.record_remote_audit_event(&RemoteAuditEvent::new(
            format!("remote-auth-{}", Uuid::new_v4()),
            utc_now(),
            Some(request_id.as_ref()),
            self.client_id,
            self.target,
            self.scope,
            self.decision,
            self.outcome,
            self.remote_addr,
            self.error_detail,
        ))
    }
}

fn bounded_request_id(request_id: &str) -> Cow<'_, str> {
    if request_id.len() <= REMOTE_AUDIT_REQUEST_ID_MAX_BYTES {
        return Cow::Borrowed(request_id);
    }
    let mut boundary = REMOTE_AUDIT_REQUEST_ID_MAX_BYTES - REMOTE_AUDIT_TRUNCATION_MARKER.len();
    while !request_id.is_char_boundary(boundary) {
        boundary -= 1;
    }
    let mut bounded = String::with_capacity(REMOTE_AUDIT_REQUEST_ID_MAX_BYTES);
    bounded.push_str(&request_id[..boundary]);
    bounded.push_str(REMOTE_AUDIT_TRUNCATION_MARKER);
    Cow::Owned(bounded)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_authorization_audit_bounds_unicode_request_ids_on_a_character_boundary() {
        let request_id = "\u{17c}".repeat(256);

        let bounded = bounded_request_id(&request_id);

        assert!(bounded.len() <= REMOTE_AUDIT_REQUEST_ID_MAX_BYTES);
        assert!(bounded.ends_with(REMOTE_AUDIT_TRUNCATION_MARKER));
        assert!(bounded.is_char_boundary(bounded.len()));
    }
}
