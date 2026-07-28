//! Test-only observability for the terminal wait path.
//!
//! The wait handler records a "started" event after it resolves its terminal and
//! a "finished" event just before it returns. Tests observe these to probe a
//! second terminal only once a wait is registered, and to assert that no wait
//! completed before that probe returned. This makes the "a wait does not
//! serialize output for another terminal" property deterministic rather than
//! racing a sleep, and it compiles out of production builds entirely.

use std::sync::{Condvar, Mutex};
use std::time::Duration;

/// Monotonic counter of terminal-wait lifecycle events, with a condvar so a test
/// can block until a target count is reached.
pub(super) struct WaitEventCounter {
    count: Mutex<u64>,
    condvar: Condvar,
}

impl WaitEventCounter {
    pub(super) fn new() -> Self {
        Self {
            count: Mutex::new(0),
            condvar: Condvar::new(),
        }
    }

    pub(super) fn record(&self) {
        *self.count.lock().unwrap() += 1;
        self.condvar.notify_all();
    }

    pub(super) fn count(&self) -> u64 {
        *self.count.lock().unwrap()
    }

    pub(super) fn wait_until(&self, target: u64, timeout: Duration) -> bool {
        let count = self.count.lock().unwrap();
        let (_count, result) = self
            .condvar
            .wait_timeout_while(count, timeout, |count| *count < target)
            .unwrap();
        !result.timed_out()
    }
}
