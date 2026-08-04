//! `db`'s interface onto [`DaemonDb`]'s constructors.
//!
//! `DaemonDb::open`/`open_in_memory`'s migration chain needs session-write
//! and timeline repair callbacks (`SessionWriteQueries`, `DaemonDbTimeline`)
//! that must stay in `harness-daemon`, so `db` itself only exposes
//! hook-taking constructors (`open_with_hooks`, `open_in_memory_with_hooks`)
//! plus the `SchemaRepairHooks` shape those hooks fill - `db` never calls
//! either trait by name, so an inherent `impl` block for this area could
//! never move into a crate `db` doesn't share with them. This trait
//! supplies the real hooks and republishes the familiar `DaemonDb::open(path)`
//! call syntax every caller already uses, the same shape
//! `daemon::remote_identity_queries` uses for its own area.

use std::path::Path;

use harness_kernel::errors::CliError;

use crate::daemon::db::timeline::DaemonDbTimeline;
use crate::daemon::db::{DaemonDb, SchemaRepairHooks, SessionWriteQueries};

/// Opens a [`DaemonDb`] with its session-write/timeline repair hooks
/// supplied, preserving the `DaemonDb::open(path)` call syntax callers
/// outside `db` already use.
pub trait DaemonDbOpen: Sized {
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    fn open(path: &Path) -> Result<Self, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    #[cfg(any(test, feature = "test-support"))]
    fn open_in_memory() -> Result<Self, CliError>;
}

impl DaemonDbOpen for DaemonDb {
    fn open(path: &Path) -> Result<Self, CliError> {
        Self::open_with_hooks(path, &repair_hooks())
    }

    #[cfg(any(test, feature = "test-support"))]
    fn open_in_memory() -> Result<Self, CliError> {
        Self::open_in_memory_with_hooks(&repair_hooks())
    }
}

fn repair_hooks() -> SchemaRepairHooks {
    SchemaRepairHooks {
        sync_session: |db, project_id, state| db.sync_session(project_id, state),
        backfill_legacy_timelines: |db| db.backfill_legacy_timelines(),
    }
}
