//! `db`'s interface onto [`DaemonDb`] and [`AsyncDaemonDb`] for the watch
//! loop's own reach into change-tracking and session-resync state.
//!
//! `db/change_tracking.rs` (sync) and `db/async_change_tracking.rs` (async)
//! persist the change-tracking half; `db/imports.rs` persists the
//! session-resync half. The traits live here, next to `daemon::watch`, the
//! only caller, rather than inside `db`: an inherent `impl` block for this
//! area could never move into a crate `db` doesn't share with it, and a
//! trait this module declares has no such problem, since Rust's orphan rule
//! only needs one of the trait or the implementing type to be local.
//!
//! Three traits, not one, because `DaemonDb` and `AsyncDaemonDb` are
//! different concrete types with disjoint method sets here: the watch
//! loop's sync-only reindex path applies prepared session resyncs, but the
//! async path never does, and each backend needs its own change-tracking
//! trait since one is `async fn` and the other cannot be.

use harness_kernel::errors::CliError;

use crate::daemon::db::{
    AsyncDaemonDb, DaemonDb, PreparedRuntimeTranscriptResync, PreparedSessionResync,
};

/// Change-tracking reads the watch loop needs from the async backend.
#[allow(
    dead_code,
    reason = "the crate-boundary seam this module exists for; every caller \
              still goes through the inherent method each one forwards to"
)]
pub(crate) trait ChangeTrackingQueries: Send + Sync {
    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    async fn current_change_sequence(&self) -> Result<i64, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    async fn load_change_tracking_since(
        &self,
        last_change_seq: i64,
    ) -> Result<Vec<(String, i64)>, CliError>;
}

/// The same two reads from the sync backend.
#[allow(
    dead_code,
    reason = "the crate-boundary seam this module exists for; every caller \
              still goes through the inherent method each one forwards to"
)]
pub(crate) trait ChangeTrackingSyncQueries {
    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    fn current_change_sequence(&self) -> Result<i64, CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    fn load_change_tracking_since(
        &self,
        last_change_seq: i64,
    ) -> Result<Vec<(String, i64)>, CliError>;
}

/// Session-resync writes the watch loop applies after preparing an import
/// off the shared database lock (`db::prepare_session_resync`,
/// `db::prepare_runtime_transcript_resync`, both free functions that never
/// touch `self` and so need no trait of their own).
#[allow(
    dead_code,
    reason = "the crate-boundary seam this module exists for; every caller \
              still goes through the inherent method each one forwards to"
)]
pub(crate) trait SessionWriteQueries {
    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    fn apply_prepared_session_resync(
        &self,
        prepared: &PreparedSessionResync,
    ) -> Result<(), CliError>;

    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    fn apply_prepared_runtime_transcript_resync(
        &self,
        prepared: &PreparedRuntimeTranscriptResync,
    ) -> Result<(), CliError>;
}

/// The async trait's one and only impl for [`AsyncDaemonDb`]. Every method is
/// a thin forward into the matching inherent method
/// (`db/async_change_tracking.rs`), kept on `Self` so nothing outside `db`
/// has to change to keep calling them by the same name.
impl ChangeTrackingQueries for AsyncDaemonDb {
    async fn current_change_sequence(&self) -> Result<i64, CliError> {
        Self::current_change_sequence(self).await
    }

    async fn load_change_tracking_since(
        &self,
        last_change_seq: i64,
    ) -> Result<Vec<(String, i64)>, CliError> {
        Self::load_change_tracking_since(self, last_change_seq).await
    }
}

/// The sync trait's one and only impl for [`DaemonDb`]. Every method is a
/// thin forward into the matching inherent method (`db/writes.rs` for
/// `current_change_sequence`, `db/change_tracking.rs` for
/// `load_change_tracking_since`), kept on `Self` so nothing outside `db` has
/// to change to keep calling them by the same name.
impl ChangeTrackingSyncQueries for DaemonDb {
    fn current_change_sequence(&self) -> Result<i64, CliError> {
        Self::current_change_sequence(self)
    }

    fn load_change_tracking_since(
        &self,
        last_change_seq: i64,
    ) -> Result<Vec<(String, i64)>, CliError> {
        Self::load_change_tracking_since(self, last_change_seq)
    }
}

/// The session-write trait's one and only impl for [`DaemonDb`]. Every
/// method is a thin forward into the matching inherent method
/// (`db/imports.rs`), kept on `Self` so nothing outside `db` has to change
/// to keep calling them by the same name.
impl SessionWriteQueries for DaemonDb {
    fn apply_prepared_session_resync(
        &self,
        prepared: &PreparedSessionResync,
    ) -> Result<(), CliError> {
        Self::apply_prepared_session_resync(self, prepared)
    }

    fn apply_prepared_runtime_transcript_resync(
        &self,
        prepared: &PreparedRuntimeTranscriptResync,
    ) -> Result<(), CliError> {
        Self::apply_prepared_runtime_transcript_resync(self, prepared)
    }
}
