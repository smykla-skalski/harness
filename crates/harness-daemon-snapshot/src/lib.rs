//! Session snapshot layer: the point-in-time project/session summaries and
//! the signal/observer/activity detail a session detail response assembles.
//!
//! Storage is reached only through [`SnapshotStorage`] (see `storage`), never
//! through a concrete `DaemonDb`/`AsyncDaemonDb`; `harness-daemon` implements
//! it for its own `DaemonDb` and depends on this crate, not the other way
//! around. This crate has no dev-dependency on `harness-daemon` - that would
//! cycle with the normal dependency edge above, and Cargo resolves a
//! dev-dependency cycle by compiling this crate twice, once per side, which
//! would give `SnapshotStorage` two distinct identities. Tests that need a
//! real `DaemonDb` instead live in `harness-daemon`'s own
//! `daemon::db::tests::snapshot_integration`; this crate's own tests exercise
//! the storage-seam traits directly or the file-based, no-db paths.
// This crate's test tree moved wholesale out of `harness-daemon`, which
// exempts its own `cfg(test)` code from pedantic for the same reason: it
// never went through a pedantic pass, so running the full lint set surfaces
// a pile of pre-existing, test-only findings about test-code shape, not
// defects. Production code keeps the full, undiminished lint set.
#![cfg_attr(test, allow(clippy::pedantic))]

mod activity;
mod detail;
mod observer;
mod signals;
mod storage;
mod summaries;
#[cfg(test)]
mod tests;

pub use activity::{
    AgentActivityAccumulator, agent_activity_summary_from_events, load_agent_activity_for,
};
pub use detail::{
    build_session_detail_core, build_session_detail_from_cached_runtime_async,
    build_session_extensions, build_session_extensions_from_cached_runtime,
    build_session_extensions_from_cached_runtime_async, session_detail,
    session_detail_from_resolved, session_detail_from_resolved_with_db,
};
pub use signals::load_signals_for;
pub use storage::{ConversationQueries, SessionSignalQueries, SnapshotStorage};
pub use summaries::{project_summaries, session_summaries, summary_from_resolved};
