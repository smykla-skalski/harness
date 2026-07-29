//! Pure remote-request resource limits.
//!
//! Defaults and the request/response middleware that enforces these limits
//! stay in `crate::daemon::http::remote_limits`: they depend on route-owned
//! body-size constants from `crate::daemon::task_board_remote_transport` and
//! `crate::daemon::http::task_board`, which this module must not reach back
//! into.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use tokio::sync::{OwnedSemaphorePermit, Semaphore, TryAcquireError};

use crate::daemon::remote_request_audit::{
    RemoteUnauthenticatedAuditAdmission, RemoteUnauthenticatedAuditLimiter,
};
use harness_kernel::errors::{CliError, CliErrorKind};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RemoteRequestLimitConfig {
    pub max_http_body_bytes: usize,
    pub max_http_header_bytes: usize,
    pub max_http_uri_bytes: usize,
    pub max_http_concurrency: usize,
    pub max_unauthenticated_audit_attempts: u32,
    pub max_unauthenticated_audit_attempts_per_remote_addr: u32,
    pub unauthenticated_audit_window: Duration,
    pub request_timeout: Duration,
    pub max_concurrent_tls_handshakes: usize,
    pub tls_handshake_timeout: Duration,
    pub max_websocket_message_bytes: usize,
    pub max_websocket_frame_bytes: usize,
    pub max_websocket_connections: usize,
    pub max_websocket_in_flight_requests: usize,
}

impl RemoteRequestLimitConfig {
    /// Validate every remote resource boundary before opening a listener.
    ///
    /// # Errors
    /// Returns [`CliError`] when a boundary is disabled or internally inconsistent.
    pub fn validate(self) -> Result<(), CliError> {
        let values = [
            ("HTTP body bytes", self.max_http_body_bytes),
            ("HTTP header bytes", self.max_http_header_bytes),
            ("HTTP URI bytes", self.max_http_uri_bytes),
            ("HTTP concurrency", self.max_http_concurrency),
            (
                "concurrent TLS handshakes",
                self.max_concurrent_tls_handshakes,
            ),
            ("WebSocket message bytes", self.max_websocket_message_bytes),
            ("WebSocket frame bytes", self.max_websocket_frame_bytes),
            ("WebSocket connections", self.max_websocket_connections),
            (
                "WebSocket in-flight requests",
                self.max_websocket_in_flight_requests,
            ),
        ];
        if let Some((name, _)) = values.into_iter().find(|(_, value)| *value == 0) {
            return Err(CliErrorKind::workflow_parse(format!(
                "remote request limits require non-zero {name}"
            ))
            .into());
        }
        if self.request_timeout.is_zero() {
            return Err(CliErrorKind::workflow_parse(
                "remote request limits require a non-zero timeout",
            )
            .into());
        }
        if self.max_unauthenticated_audit_attempts == 0
            || self.max_unauthenticated_audit_attempts_per_remote_addr == 0
        {
            return Err(CliErrorKind::workflow_parse(
                "remote request limits require non-zero unauthenticated audit attempt limits",
            )
            .into());
        }
        if self.unauthenticated_audit_window.is_zero() {
            return Err(CliErrorKind::workflow_parse(
                "remote request limits require a non-zero unauthenticated audit window",
            )
            .into());
        }
        if self.tls_handshake_timeout.is_zero() {
            return Err(CliErrorKind::workflow_parse(
                "remote request limits require a non-zero TLS handshake timeout",
            )
            .into());
        }
        if self.max_websocket_frame_bytes > self.max_websocket_message_bytes {
            return Err(CliErrorKind::workflow_parse(
                "remote request limits require the WebSocket frame limit to fit within the message limit",
            )
            .into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub struct RemoteRequestLimits {
    config: RemoteRequestLimitConfig,
    http_permits: Arc<Semaphore>,
    websocket_permits: Arc<Semaphore>,
    unauthenticated_audit_limiter: Arc<Mutex<RemoteUnauthenticatedAuditLimiter>>,
}

impl RemoteRequestLimits {
    /// Build runtime limit state from validated configuration.
    ///
    /// # Errors
    /// Returns [`CliError`] when the configuration disables a required limit.
    pub fn new(config: RemoteRequestLimitConfig) -> Result<Self, CliError> {
        config.validate()?;
        Ok(Self {
            config,
            http_permits: Arc::new(Semaphore::new(config.max_http_concurrency)),
            websocket_permits: Arc::new(Semaphore::new(config.max_websocket_connections)),
            unauthenticated_audit_limiter: Arc::new(Mutex::new(
                RemoteUnauthenticatedAuditLimiter::new(
                    config.max_unauthenticated_audit_attempts,
                    config.max_unauthenticated_audit_attempts_per_remote_addr,
                    config.unauthenticated_audit_window,
                ),
            )),
        })
    }

    #[must_use]
    pub const fn config(&self) -> RemoteRequestLimitConfig {
        self.config
    }

    pub(crate) fn try_http_permit(&self) -> Result<OwnedSemaphorePermit, TryAcquireError> {
        Arc::clone(&self.http_permits).try_acquire_owned()
    }

    pub(crate) fn try_websocket_permit(&self) -> Result<OwnedSemaphorePermit, TryAcquireError> {
        Arc::clone(&self.websocket_permits).try_acquire_owned()
    }

    pub(crate) fn admit_unauthenticated_audit(
        &self,
        remote_addr: &str,
    ) -> RemoteUnauthenticatedAuditAdmission {
        self.unauthenticated_audit_limiter
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .admit(remote_addr)
    }

    #[must_use]
    pub(crate) fn unauthenticated_audit_retry_after_seconds(&self) -> u64 {
        let window = self.config.unauthenticated_audit_window;
        window
            .as_secs()
            .saturating_add(u64::from(window.subsec_nanos() != 0))
            .max(1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The `Default` impl for `RemoteRequestLimits`/`RemoteRequestLimitConfig`
    // lives in `crate::daemon::http::remote_limits` (it needs an http-owned
    // body-size const), so this constructs its own config rather than relying
    // on `RemoteRequestLimits::default()`.
    fn test_limits() -> RemoteRequestLimits {
        RemoteRequestLimits::new(RemoteRequestLimitConfig {
            max_http_body_bytes: 1024,
            max_http_header_bytes: 1024,
            max_http_uri_bytes: 1024,
            max_http_concurrency: 4,
            max_unauthenticated_audit_attempts: 60,
            max_unauthenticated_audit_attempts_per_remote_addr: 5,
            unauthenticated_audit_window: Duration::from_secs(60),
            request_timeout: Duration::from_secs(30),
            max_concurrent_tls_handshakes: 4,
            tls_handshake_timeout: Duration::from_secs(5),
            max_websocket_message_bytes: 1024,
            max_websocket_frame_bytes: 1024,
            max_websocket_connections: 4,
            max_websocket_in_flight_requests: 4,
        })
        .expect("valid test remote request limits")
    }

    #[test]
    fn unauthenticated_audit_limiter_recovers_from_mutex_poisoning() {
        let limits = test_limits();
        let limiter = Arc::clone(&limits.unauthenticated_audit_limiter);
        let poisoned = std::panic::catch_unwind(move || {
            let _guard = limiter.lock().expect("lock limiter before poisoning");
            panic!("poison the test limiter");
        });

        assert!(poisoned.is_err());
        assert_eq!(
            limits.admit_unauthenticated_audit("127.0.0.1"),
            RemoteUnauthenticatedAuditAdmission::Audit,
        );
    }
}
