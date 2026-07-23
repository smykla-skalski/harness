use std::collections::{BTreeMap, VecDeque};
use std::sync::Arc;
use std::time::{Duration, Instant};

use uuid::Uuid;

use super::db::AsyncDaemonDb;
use super::remote::RemoteAccessScope;
use super::remote_identity::{RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision};
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

const DEFAULT_MAX_TRACKED_UNAUTHENTICATED_ADDRESSES: usize = 4096;

/// Decision for a failed remote authentication before it is persisted as an
/// audit event.
///
/// The one `audit` decision after a limit is reached preserves an aggregate
/// security signal without turning every rejected packet into a database write.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemoteUnauthenticatedAuditAdmission {
    Audit,
    RateLimited { audit: bool },
}

#[derive(Debug, Clone, Copy)]
struct UnauthenticatedAttemptWindow {
    started_at: Instant,
    attempts: u32,
}

impl UnauthenticatedAttemptWindow {
    const fn new(started_at: Instant) -> Self {
        Self {
            started_at,
            attempts: 1,
        }
    }

    fn is_expired(self, now: Instant, window: Duration) -> bool {
        now.saturating_duration_since(self.started_at) >= window
    }
}

/// Bounded, windowed admission for unauthenticated remote audit writes.
///
/// A process tracks at most `max_addresses` trusted peer-address keys. The
/// FIFO contains one entry per key and expired windows are removed before a
/// new key is recorded, so attacker-controlled addresses cannot grow memory
/// without bound. A global window also caps durable denial writes across many
/// source addresses.
#[derive(Debug)]
pub(crate) struct RemoteUnauthenticatedAuditLimiter {
    max_attempts: u32,
    max_attempts_per_address: u32,
    max_addresses: usize,
    window: Duration,
    global: UnauthenticatedAttemptWindow,
    rate_limit_audited: bool,
    address_attempts: BTreeMap<String, UnauthenticatedAttemptWindow>,
    address_order: VecDeque<String>,
}

impl RemoteUnauthenticatedAuditLimiter {
    #[must_use]
    pub(crate) fn new(max_attempts: u32, max_attempts_per_address: u32, window: Duration) -> Self {
        Self::new_bounded(
            max_attempts,
            max_attempts_per_address,
            DEFAULT_MAX_TRACKED_UNAUTHENTICATED_ADDRESSES,
            window,
        )
    }

    fn new_bounded(
        max_attempts: u32,
        max_attempts_per_address: u32,
        max_addresses: usize,
        window: Duration,
    ) -> Self {
        let now = Instant::now();
        Self {
            max_attempts: max_attempts.max(1),
            max_attempts_per_address: max_attempts_per_address.max(1),
            max_addresses: max_addresses.max(1),
            window: if window.is_zero() {
                Duration::from_secs(1)
            } else {
                window
            },
            global: UnauthenticatedAttemptWindow {
                started_at: now,
                attempts: 0,
            },
            rate_limit_audited: false,
            address_attempts: BTreeMap::new(),
            address_order: VecDeque::new(),
        }
    }

    #[must_use]
    pub(crate) fn admit(&mut self, remote_addr: &str) -> RemoteUnauthenticatedAuditAdmission {
        self.admit_at(remote_addr, Instant::now())
    }

    #[cfg(test)]
    #[must_use]
    fn new_for_tests(
        max_attempts: u32,
        max_attempts_per_address: u32,
        max_addresses: usize,
        window: Duration,
    ) -> Self {
        Self::new_bounded(
            max_attempts,
            max_attempts_per_address,
            max_addresses,
            window,
        )
    }

    #[cfg(test)]
    #[must_use]
    fn admit_at_for_tests(
        &mut self,
        remote_addr: &str,
        now: Instant,
    ) -> RemoteUnauthenticatedAuditAdmission {
        self.admit_at(remote_addr, now)
    }

    #[cfg(test)]
    #[must_use]
    fn tracked_addresses_for_tests(&self) -> usize {
        self.address_attempts.len()
    }

    fn admit_at(&mut self, remote_addr: &str, now: Instant) -> RemoteUnauthenticatedAuditAdmission {
        self.reset_global_window_if_expired(now);
        self.prune_expired_addresses(now);
        self.reset_address_window_if_expired(remote_addr, now);

        if self.global.attempts >= self.max_attempts || self.address_limit_reached(remote_addr) {
            return self.rate_limited();
        }

        self.record_address_attempt(remote_addr, now);
        self.global.attempts = self.global.attempts.saturating_add(1);
        RemoteUnauthenticatedAuditAdmission::Audit
    }

    fn reset_global_window_if_expired(&mut self, now: Instant) {
        if self.global.is_expired(now, self.window) {
            self.global = UnauthenticatedAttemptWindow {
                started_at: now,
                attempts: 0,
            };
            self.rate_limit_audited = false;
        }
    }

    fn prune_expired_addresses(&mut self, now: Instant) {
        while let Some(remote_addr) = self.address_order.front().cloned() {
            let expired = self
                .address_attempts
                .get(&remote_addr)
                .is_none_or(|attempt| attempt.is_expired(now, self.window));
            if !expired {
                break;
            }
            self.address_order.pop_front();
            self.address_attempts.remove(&remote_addr);
        }
    }

    fn reset_address_window_if_expired(&mut self, remote_addr: &str, now: Instant) {
        if self
            .address_attempts
            .get(remote_addr)
            .is_some_and(|attempt| attempt.is_expired(now, self.window))
        {
            self.remove_address(remote_addr);
        }
    }

    fn address_limit_reached(&self, remote_addr: &str) -> bool {
        self.address_attempts
            .get(remote_addr)
            .is_some_and(|attempt| attempt.attempts >= self.max_attempts_per_address)
    }

    fn rate_limited(&mut self) -> RemoteUnauthenticatedAuditAdmission {
        let audit = !self.rate_limit_audited;
        self.rate_limit_audited = true;
        RemoteUnauthenticatedAuditAdmission::RateLimited { audit }
    }

    fn record_address_attempt(&mut self, remote_addr: &str, now: Instant) {
        if let Some(attempt) = self.address_attempts.get_mut(remote_addr) {
            attempt.attempts = attempt.attempts.saturating_add(1);
            return;
        }
        while self.address_attempts.len() >= self.max_addresses {
            let Some(oldest) = self.address_order.pop_front() else {
                self.address_attempts.clear();
                break;
            };
            self.address_attempts.remove(&oldest);
        }
        let remote_addr = remote_addr.to_string();
        self.address_order.push_back(remote_addr.clone());
        self.address_attempts
            .insert(remote_addr, UnauthenticatedAttemptWindow::new(now));
    }

    fn remove_address(&mut self, remote_addr: &str) {
        self.address_attempts.remove(remote_addr);
        if let Some(index) = self
            .address_order
            .iter()
            .position(|entry| entry == remote_addr)
        {
            self.address_order.remove(index);
        }
    }
}

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
        let event_id = format!("remote-auth-{}", Uuid::new_v4());
        let event = RemoteAuditEvent::new(
            event_id.clone(),
            utc_now(),
            Some(self.request_id),
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
    fn unauthenticated_audit_limiter_caps_global_writes_and_records_one_aggregate_signal() {
        let now = Instant::now();
        let mut limiter =
            RemoteUnauthenticatedAuditLimiter::new_for_tests(2, 2, 8, Duration::from_secs(60));

        assert_eq!(
            limiter.admit_at_for_tests("203.0.113.10", now),
            RemoteUnauthenticatedAuditAdmission::Audit
        );
        assert_eq!(
            limiter.admit_at_for_tests("203.0.113.11", now),
            RemoteUnauthenticatedAuditAdmission::Audit
        );
        assert_eq!(
            limiter.admit_at_for_tests("203.0.113.12", now),
            RemoteUnauthenticatedAuditAdmission::RateLimited { audit: true }
        );
        assert_eq!(
            limiter.admit_at_for_tests("203.0.113.13", now),
            RemoteUnauthenticatedAuditAdmission::RateLimited { audit: false }
        );
    }

    #[test]
    fn unauthenticated_audit_limiter_bounds_and_expires_remote_address_keys() {
        let now = Instant::now();
        let mut limiter =
            RemoteUnauthenticatedAuditLimiter::new_for_tests(8, 8, 2, Duration::from_secs(60));

        for remote_addr in ["203.0.113.10", "203.0.113.11", "203.0.113.12"] {
            assert_eq!(
                limiter.admit_at_for_tests(remote_addr, now),
                RemoteUnauthenticatedAuditAdmission::Audit
            );
        }
        assert_eq!(limiter.tracked_addresses_for_tests(), 2);

        assert_eq!(
            limiter.admit_at_for_tests("203.0.113.13", now + Duration::from_secs(60)),
            RemoteUnauthenticatedAuditAdmission::Audit
        );
        assert_eq!(limiter.tracked_addresses_for_tests(), 1);
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
