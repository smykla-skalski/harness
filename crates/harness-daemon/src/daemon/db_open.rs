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

use std::future::Future;
use std::path::Path;

use harness_kernel::errors::CliError;

use crate::daemon::db::DaemonDbTimeline;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb, SchemaRepairHooks, SessionWriteQueries};

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

/// Connects an [`AsyncDaemonDb`], supplying the same repair hooks [`DaemonDbOpen`]
/// does: `connect` primes a legacy on-disk database through a synchronous
/// [`DaemonDb::open_with_hooks`] before the async pool attaches, so it needs
/// the real hooks too, not just the outer async caller.
pub trait AsyncDaemonDbConnect: Sized {
    /// # Errors
    /// Returns [`CliError`] when the pool or schema probe cannot be initialized.
    fn connect(path: &Path) -> impl Future<Output = Result<Self, CliError>> + Send;
}

impl AsyncDaemonDbConnect for AsyncDaemonDb {
    fn connect(path: &Path) -> impl Future<Output = Result<Self, CliError>> + Send {
        let hooks = repair_hooks();
        async move { Self::connect_with_hooks(path, &hooks).await }
    }
}

fn repair_hooks() -> SchemaRepairHooks {
    SchemaRepairHooks {
        sync_session: |db, project_id, state| db.sync_session(project_id, state),
        backfill_legacy_timelines: |db| db.backfill_legacy_timelines(),
    }
}
