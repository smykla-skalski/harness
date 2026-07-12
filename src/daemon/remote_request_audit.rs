use std::sync::{Arc, Mutex};

use uuid::Uuid;

use super::db::DaemonDb;
use super::remote::RemoteAccessScope;
use super::remote_identity::{RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision};
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

pub(crate) struct RemoteAuthorizationAudit<'a> {
    request_id: &'a str,
    client_id: Option<&'a str>,
    target: &'a str,
    scope: RemoteAccessScope,
    decision: RemoteAuditScopeDecision,
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
            remote_addr,
            error_detail: None,
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
        let outcome = match self.decision {
            RemoteAuditScopeDecision::Allowed => RemoteAuditOutcome::Success,
            RemoteAuditScopeDecision::Denied => RemoteAuditOutcome::Failure,
        };
        db.record_remote_audit_event(&RemoteAuditEvent::new(
            format!("remote-auth-{}", Uuid::new_v4()),
            utc_now(),
            Some(self.request_id),
            self.client_id,
            self.target,
            self.scope,
            self.decision,
            outcome,
            self.remote_addr,
            self.error_detail,
        ))
    }
}
