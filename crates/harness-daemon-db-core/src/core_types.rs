use std::borrow::Cow;
use std::cell::RefCell;
use std::fmt;
use std::path::PathBuf;

use harness_kernel::errors::{CliError, CliErrorKind};
use rusqlite::Connection;

use super::activity_fold_cache;

/// Session ids eligible for liveness reconciliation: non-archived sessions in a
/// liveness-eligible status (the `snake_case` labels mirror
/// `SessionStatus::is_liveness_eligible`) that still carry at least one agent.
/// Projects only the id column so the periodic liveness sweep never
/// deserializes full session state.
pub const LIVENESS_CANDIDATE_IDS_SQL: &str = "SELECT s.session_id
 FROM sessions s
 WHERE s.archived_at IS NULL
   AND s.status IN ('awaiting_leader', 'active', 'leaderless_degraded')
   AND COALESCE(json_extract(s.metrics_json, '$.agent_count'), 0) > 0
 ORDER BY s.session_id";

/// `SQLite`-backed canonical storage for durable harness daemon state.
///
/// Operational files remain only for integration boundaries that cannot move
/// into the database.
// Fields are `pub`, not `pub(crate)`: every extension trait that used to be
// an inherent `impl DaemonDb` block inside this struct's defining module
// (before issue #1231 split them out) now lives in `harness-daemon`, a
// different crate, and reaches these fields directly the same way it always
// has - Rust privacy has no "friend crate" tier, so `pub` is the only
// modifier that preserves that access across the crate boundary.
pub struct DaemonDb {
    pub conn: Connection,
    pub path: Option<PathBuf>,
    /// Per-agent running activity folds for the live conversation append path.
    pub activity_fold: RefCell<activity_fold_cache::ActivityFoldCache>,
}

impl fmt::Debug for DaemonDb {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DaemonDb").finish_non_exhaustive()
    }
}

// `pub`, not `pub(crate)`: `harness-db-schema`'s own dev-dependency tests
// assert a freshly migrated database's stamped version against this
// constant, the same reason `AsyncDaemonDb` is `pub` rather than
// `pub(crate)`.
pub const SCHEMA_VERSION: &str = "63";

#[must_use]
pub fn db_error(detail: impl Into<Cow<'static, str>>) -> CliError {
    CliError::from(CliErrorKind::workflow_io(detail))
}

#[must_use]
pub fn canonical_db_unavailable(operation: &str) -> CliError {
    CliError::from(CliErrorKind::workflow_io(format!(
        "daemon canonical database unavailable for {operation}"
    )))
}

#[must_use]
#[expect(
    clippy::cast_possible_wrap,
    reason = "intentional bit-pattern reinterpretation for SQLite storage"
)]
pub const fn i64_from_u64(value: u64) -> i64 {
    value as i64
}

#[must_use]
#[expect(
    clippy::cast_sign_loss,
    reason = "intentional bit-pattern reinterpretation for SQLite storage"
)]
pub const fn u64_from_i64(value: i64) -> u64 {
    value as u64
}

#[must_use]
pub fn usize_from_i64(value: i64) -> usize {
    usize::try_from(value).unwrap_or(0)
}
