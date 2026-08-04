//! Local newtype wrappers over [`DaemonDb`]/[`AsyncDaemonDb`] so `harness-daemon`
//! can keep implementing traits owned by sibling crates for them.
//!
//! Both structs moved into `harness-daemon-db-core` for #1231, so a trait
//! defined in another sibling crate (`harness-task-board`,
//! `harness-daemon-session-service`, `harness-daemon-watch`,
//! `harness-policy-graph-store`, `harness-task-board-provider-sync`,
//! `harness-daemon-snapshot`, ...) and `DaemonDb`/`AsyncDaemonDb` are now both
//! foreign to this crate, so Rust's orphan rule blocks implementing the
//! trait directly for them. These wrappers are local to `harness-daemon`, so
//! implementing a foreign trait for one has no such problem; every impl
//! delegates to the session/task-board/watch extension traits that must stay
//! in this crate. Mirrors `daemon::db_timeline_source::DaemonDbTimelineHandle`'s
//! existing shape for `TimelineDbSource`.

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};

// Owns `DaemonDb` by value: `harness-daemon-watch`'s `WatchStorage` bound is
// carried inside the daemon's single canonical `Arc<Mutex<DaemonDb>>` handle,
// which every HTTP/websocket/watch caller shares and locks for the duration
// of one operation, so the wrapper has to be the type actually stored in
// that `Mutex` rather than a short-lived borrow. `Deref`/`DerefMut` to
// `DaemonDb` mean every existing call site that locks the mutex and calls a
// `DaemonDb` method through the guard keeps compiling unchanged; only the
// `Mutex<DaemonDb>` type annotations at its construction and threading sites
// need to say `Mutex<DaemonDbOwnedHandle>` instead.
pub struct DaemonDbOwnedHandle(pub DaemonDb);

impl std::fmt::Debug for DaemonDbOwnedHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("DaemonDbOwnedHandle").field(&self.0).finish()
    }
}

impl std::ops::Deref for DaemonDbOwnedHandle {
    type Target = DaemonDb;

    fn deref(&self) -> &DaemonDb {
        &self.0
    }
}

impl std::ops::DerefMut for DaemonDbOwnedHandle {
    fn deref_mut(&mut self) -> &mut DaemonDb {
        &mut self.0
    }
}

// Owns `AsyncDaemonDb` by value, not by reference: `AsyncDaemonDb` clones
// cheaply (its pool is `Arc`-backed internally), and several call sites need
// `Arc<AsyncDaemonDbHandle>` to outlive the current stack frame (executor and
// registry construction), which a borrowed handle's lifetime could not do.
#[derive(Clone, Debug)]
pub struct AsyncDaemonDbHandle(pub AsyncDaemonDb);

impl std::ops::Deref for AsyncDaemonDbHandle {
    type Target = AsyncDaemonDb;

    fn deref(&self) -> &AsyncDaemonDb {
        &self.0
    }
}

impl std::ops::DerefMut for AsyncDaemonDbHandle {
    fn deref_mut(&mut self) -> &mut AsyncDaemonDb {
        &mut self.0
    }
}
