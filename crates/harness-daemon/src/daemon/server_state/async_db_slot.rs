use std::sync::{Arc, OnceLock};

/// Slot for the daemon's asynchronous database handle, populated once startup
/// finishes opening it. Generic over the async database type so this module
/// does not track `crate::daemon::db`'s own shape.
pub struct AsyncDaemonDbSlot<T> {
    inner: Arc<OnceLock<Arc<T>>>,
}

// Hand-written: `#[derive(Clone)]` would require `T: Clone`, but cloning the
// slot only bumps the outer `Arc`'s refcount.
impl<T> Clone for AsyncDaemonDbSlot<T> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

// Hand-written for the same reason: `OnceLock::default()` needs no bound on
// `T`, but `#[derive(Default)]` would add `T: Default` anyway.
impl<T> Default for AsyncDaemonDbSlot<T> {
    fn default() -> Self {
        Self {
            inner: Arc::new(OnceLock::new()),
        }
    }
}

impl<T> AsyncDaemonDbSlot<T> {
    #[must_use]
    pub fn empty() -> Self {
        Self::default()
    }

    #[must_use]
    pub(crate) fn from_inner(inner: Arc<OnceLock<Arc<T>>>) -> Self {
        Self { inner }
    }

    #[must_use]
    pub(crate) fn get(&self) -> Option<&Arc<T>> {
        self.inner.get()
    }
}
