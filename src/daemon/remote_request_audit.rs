use std::borrow::Cow;
use std::sync::Arc;

use uuid::Uuid;

use super::db::AsyncDaemonDb;
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RemoteAuthorizationAuditReceipt {
    event_id: String,
    decision: RemoteAuditScopeDecision,
}

impl RemoteAuthorizationAuditReceipt {
    pub(crate) async fn mark_failed(
        &self,
        db: Option<&Arc<AsyncDaemonDb>>,
        error_detail: &str,
    ) -> Result<(), CliError> {
        if self.decision == RemoteAuditScopeDecision::Denied {
            return Ok(());
        }
        let db = db.ok_or_else(remote_audit_store_unavailable)?;
        db.mark_remote_audit_event_failed(&self.event_id, error_detail)
            .await
    }
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
    pub(crate) async fn record(
        self,
        db: Option<&Arc<AsyncDaemonDb>>,
    ) -> Result<RemoteAuthorizationAuditReceipt, CliError> {
        let db = db.ok_or_else(remote_audit_store_unavailable)?;
        let request_id = bounded_request_id(self.request_id);
        let event_id = format!("remote-auth-{}", Uuid::new_v4());
        let event = RemoteAuditEvent::new(
            event_id.clone(),
            utc_now(),
            Some(request_id.as_ref()),
            self.client_id,
            self.target,
            self.scope,
            self.decision,
            self.outcome,
            self.remote_addr,
            self.error_detail,
        );
        db.record_remote_audit_event(&event).await?;
        Ok(RemoteAuthorizationAuditReceipt {
            event_id,
            decision: self.decision,
        })
    }
}

fn remote_audit_store_unavailable() -> CliError {
    CliError::from(CliErrorKind::workflow_io(
        "remote authorization audit store is unavailable",
    ))
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
    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration;

    use rusqlite::TransactionBehavior;
    use tempfile::tempdir;

    use super::super::db::DaemonDb;

    #[test]
    fn remote_authorization_audit_bounds_unicode_request_ids_on_a_character_boundary() {
        let request_id = "\u{17c}".repeat(256);

        let bounded = bounded_request_id(&request_id);

        assert!(bounded.len() <= REMOTE_AUDIT_REQUEST_ID_MAX_BYTES);
        assert!(bounded.ends_with(REMOTE_AUDIT_TRUNCATION_MARKER));
        assert!(bounded.is_char_boundary(bounded.len()));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn remote_authorization_audit_yields_while_sqlite_writer_finishes() {
        let temp = tempdir().expect("create audit contention tempdir");
        let db_path = temp.path().join("harness.db");
        drop(DaemonDb::open(&db_path).expect("initialize daemon database"));
        let db = Arc::new(
            AsyncDaemonDb::connect(&db_path)
                .await
                .expect("open async daemon database"),
        );
        let (writer_ready_tx, writer_ready_rx) = mpsc::channel();
        let (release_writer_tx, release_writer_rx) = mpsc::channel();
        let writer_path = db_path.clone();
        let writer = thread::spawn(move || {
            let mut connection =
                rusqlite::Connection::open(writer_path).expect("open contending SQLite writer");
            let transaction = connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .expect("hold SQLite write transaction");
            writer_ready_tx.send(()).expect("signal writer ready");
            release_writer_rx.recv().expect("receive writer release");
            transaction.commit().expect("commit contending writer");
        });
        writer_ready_rx.recv().expect("wait for SQLite writer");

        let release = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(25)).await;
            release_writer_tx.send(()).expect("release SQLite writer");
        });
        let receipt = RemoteAuthorizationAudit::allowed(
            "audit-contention-request",
            "remote-client",
            "reviews.files_list",
            RemoteAccessScope::Read,
            Some("203.0.113.10"),
        )
        .record(Some(&db))
        .await
        .expect("persist remote audit after contending writer releases");

        release.await.expect("join writer release task");
        writer.join().expect("join contending SQLite writer");
        let events = DaemonDb::open(&db_path)
            .expect("open daemon database for audit verification")
            .load_remote_audit_events(10)
            .expect("load remote audits");
        assert!(
            events
                .iter()
                .any(|event| event.event_id == receipt.event_id)
        );
    }
}
