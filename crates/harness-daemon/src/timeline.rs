//! Session-timeline construction moved into `harness_timeline`; see that
//! crate for the merge logic. Re-exported flat here so the daemon's own
//! `db`, `service`, and `http` call sites keep resolving `crate::timeline::*`
//! (surfaced as `daemon::timeline` by `daemon::mod`) without touching every
//! one of them.
pub use harness_timeline::*;

// `TimelinePayloadScope`, the pure entry constructors, and the db-hybrid
// builder were `pub(crate)`/`pub(super)` before this module moved out to
// `harness_timeline`. They need to be `pub` there for `daemon::db` (now a
// dependent crate's caller, not a sibling module) to reach them, but nothing
// outside `harness-daemon` should rely on them, so narrow them back here the
// way `task_board.rs` narrows its own glob re-export.
#[expect(
    hidden_glob_reexports,
    reason = "narrows public items back to pub(crate) for harness-daemon-internal callers only"
)]
pub(crate) use harness_timeline::{
    TimelinePayloadScope, checkpoint_entry, conversation_entry, log_entry_timeline_entry,
    session_timeline_from_resolved_with_db_scope, session_timeline_with_scope,
};
