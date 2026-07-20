//! Cooperative cancellation for client calls that can block for a long time.
//!
//! `session/request_permission` waits on a human decision and
//! `terminal/wait_for_exit` waits on a child process, so both can outlive the
//! agent's interest in the answer. The protocol layer trips the token when the
//! agent sends `$/cancel_request`; the waiting code observes it and unwinds
//! instead of holding a blocking thread until its own deadline.
//!
//! Waiters come in two flavours, so the token carries both wake paths: async
//! waiters await [`ClientCallCancel::cancelled`], and blocking waiters parked
//! on a condvar register a wake callback with
//! [`ClientCallCancel::on_cancel`].

use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

use std::sync::Arc;
use tokio::sync::Notify;

type WakeCallback = Box<dyn Fn() + Send + Sync>;

#[derive(Clone, Default)]
pub struct ClientCallCancel {
    state: Arc<CancelState>,
}

#[derive(Default)]
struct CancelState {
    cancelled: AtomicBool,
    notify: Notify,
    wake: Mutex<Option<WakeCallback>>,
}

impl ClientCallCancel {
    /// Trip the token. Idempotent: later calls are no-ops.
    pub fn cancel(&self) {
        if self.state.cancelled.swap(true, Ordering::AcqRel) {
            return;
        }
        self.state.notify.notify_waiters();
        let wake = self.take_wake_callback();
        if let Some(wake) = wake {
            wake();
        }
    }

    #[must_use]
    pub fn is_cancelled(&self) -> bool {
        self.state.cancelled.load(Ordering::Acquire)
    }

    /// Resolve once the token is tripped, immediately if it already was.
    pub async fn cancelled(&self) {
        loop {
            if self.is_cancelled() {
                return;
            }
            // Register before re-checking so a cancel racing this point is
            // still delivered to the notified future rather than lost.
            let notified = self.state.notify.notified();
            if self.is_cancelled() {
                return;
            }
            notified.await;
        }
    }

    /// Register the wake callback for a blocking waiter. Runs the callback
    /// immediately when the token is already tripped, so a waiter that
    /// registers late still unblocks.
    pub fn on_cancel(&self, wake: impl Fn() + Send + Sync + 'static) {
        if self.is_cancelled() {
            wake();
            return;
        }
        {
            let mut slot = self.lock_wake();
            *slot = Some(Box::new(wake));
        }
        if self.is_cancelled()
            && let Some(wake) = self.take_wake_callback()
        {
            wake();
        }
    }

    /// Drop the registered wake callback once the waiter has finished, so a
    /// later cancel does not poke a dead waiter.
    pub fn clear_wake(&self) {
        let _ = self.take_wake_callback();
    }

    fn take_wake_callback(&self) -> Option<WakeCallback> {
        self.lock_wake().take()
    }

    fn lock_wake(&self) -> std::sync::MutexGuard<'_, Option<WakeCallback>> {
        self.state
            .wake
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// Token for test call sites that do not exercise cancellation.
#[cfg(test)]
pub(crate) fn no_cancel() -> ClientCallCancel {
    ClientCallCancel::default()
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::AtomicU64;
    use std::time::Duration;

    use super::*;

    #[test]
    fn cancel_runs_a_registered_wake_callback() {
        let cancel = ClientCallCancel::default();
        let woken = Arc::new(AtomicU64::new(0));
        let counter = Arc::clone(&woken);
        cancel.on_cancel(move || {
            counter.fetch_add(1, Ordering::SeqCst);
        });

        cancel.cancel();
        cancel.cancel();

        assert!(cancel.is_cancelled());
        assert_eq!(
            woken.load(Ordering::SeqCst),
            1,
            "wake must fire exactly once"
        );
    }

    #[test]
    fn late_registration_wakes_immediately() {
        let cancel = ClientCallCancel::default();
        cancel.cancel();
        let woken = Arc::new(AtomicU64::new(0));
        let counter = Arc::clone(&woken);

        cancel.on_cancel(move || {
            counter.fetch_add(1, Ordering::SeqCst);
        });

        assert_eq!(woken.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn cancelled_resolves_after_cancel() {
        let cancel = ClientCallCancel::default();
        let waiter = cancel.clone();
        let task = tokio::spawn(async move { waiter.cancelled().await });

        tokio::time::sleep(Duration::from_millis(20)).await;
        cancel.cancel();

        tokio::time::timeout(Duration::from_secs(2), task)
            .await
            .expect("cancelled should resolve")
            .expect("waiter task should not panic");
    }

    #[tokio::test]
    async fn cancelled_returns_immediately_when_already_cancelled() {
        let cancel = ClientCallCancel::default();
        cancel.cancel();

        tokio::time::timeout(Duration::from_millis(200), cancel.cancelled())
            .await
            .expect("already-cancelled token must not block");
    }
}
