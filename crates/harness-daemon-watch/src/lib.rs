//! Daemon watch loop and filesystem refresh logic.
//!
//! Storage and service behavior enter through caller-owned traits, so the
//! watch loop builds without depending on `harness-daemon`.
#![cfg_attr(test, allow(clippy::pedantic))]

mod loops;
mod paths;
mod refresh;
mod service_port;
mod state;
mod storage;

#[cfg(test)]
mod path_tests;
#[cfg(test)]
mod pending_tests;
#[cfg(test)]
mod snapshot_tests;
#[cfg(test)]
mod test_support;

pub use loops::{
    liveness_reconcile_due, poll_change_tracking, poll_change_tracking_async, spawn_watch_loop,
};
pub use refresh::{emit_watch_changes, emit_watch_changes_with};
pub use service_port::WatchServicePort;
pub use state::WatchChanges;
pub use storage::{AsyncWatchStorage, WatchStorage};
