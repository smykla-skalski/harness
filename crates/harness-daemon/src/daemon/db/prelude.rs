//! Glob-import prelude for the non-task-board `db` extension traits.
//!
//! A caller outside `db/` that needs to call methods on `DaemonDb` or
//! `AsyncDaemonDb` through these traits gets exactly one line,
//! `use crate::daemon::db::prelude::*;`, instead of one `use` per trait per
//! file. Registering a new trait here is the only change a future trait
//! needs; no caller import ever has to change again. Mirrors
//! `task_board::prelude`, scoped to the traits declared directly under
//! `db/` rather than under `db/task_board/`.
//!
//! Re-exports through `super::TraitName` (the top-level `db` re-export)
//! rather than reaching into each submodule directly, so that top-level
//! re-export counts as used even when every caller reaches the trait
//! through this glob instead of by name.
//!
//! Verified collision-free: no two traits re-exported here share a method
//! name for the same receiver type (`DaemonDb` or `AsyncDaemonDb`), which is
//! what makes the glob import unambiguous.

pub(crate) use super::{
    AsyncAgentResolutionQueries, AsyncAgentTurnRunQueries, AsyncChangeTrackingQueries,
    AsyncConversationSyncQueries, AsyncDaemonTransactions, AsyncDiagnosticsQueries,
    AsyncRuntimeSnapshotQueries, AsyncSessionStateQueries, AsyncSessionSummaryQueries,
    AsyncSessionWriteQueries, AsyncSignalIndexQueries, AsyncSignalReadQueries,
    AsyncTimelineWindowQueries, DaemonDbOpen, RuntimeSnapshotQueries, SessionCoreQueries,
    SessionSummaryQueries, SessionWriteQueries, SignalIndexQueries,
};
// `ChangeTrackingQueries` (the sync counterpart) is deliberately not
// re-exported here: every current caller outside `db/` already reaches it
// through a direct `crate::daemon::db::ChangeTrackingQueries` import (see
// `watch/storage.rs`), so including it here would be an unused glob member.
// Add it back the moment a glob-only caller needs it.
//
// `AsyncDaemonDbConnect` is excluded for the same reason: every current
// `AsyncDaemonDb::connect` caller already imports it directly.
