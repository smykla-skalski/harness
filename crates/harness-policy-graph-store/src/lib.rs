//! Durable persistence for the review-policy graph: canvases, decisions, and
//! approval grants. Extracted from `harness-daemon`'s `db/policy`, which
//! reached these tables only for two things: `service::reviews`-adjacent
//! code reading and writing the canvas workspace and decision feed through
//! `AsyncDaemonDb`, and task-board's dispatch path consuming an approval
//! grant directly through the `_in_tx` functions below. `harness-daemon`
//! keeps both call shapes working unchanged: `daemon::reviews_store` owns
//! the `PolicyGraphQueries` trait and its thin `AsyncDaemonDb`/`DaemonDb`
//! forwards (see #1115's decision on this cluster), and task-board now
//! depends on this crate directly for the `_in_tx` functions instead of
//! reaching across `db` by module path.

mod approval_grants;
mod decisions_async;
mod mapper;
mod rows;
mod sql;
mod store_async;
mod store_canvas_async;
mod store_sync;

use std::borrow::Cow;
use std::future::Future;

use harness_kernel::errors::{CliError, CliErrorKind};
use sqlx::{Sqlite, SqlitePool, Transaction};

pub use approval_grants::{
    NewApprovalGrant, approval_grant, consume_approval_grant_in_tx,
    consume_approval_grant_in_tx_at, count_pending_approval_grants,
    count_pending_approval_grants_at, ensure_pending_approval_grant, insert_pending_grant_at,
    list_pending_approval_grants, list_pending_approval_grants_at, live_approval_grant,
    live_approval_grant_at, live_approval_grant_in_tx_at, resolve_approval_grant,
    resolve_approval_grant_at, restore_consumed_approval_grant_in_tx_at, revoke_approval_grant,
    revoke_approval_grant_at,
};
pub use decisions_async::{
    prune_policy_decisions, recent_policy_decisions_for_canvas, record_policy_decision_row,
};
pub use store_async::{
    load_policy_workspace, load_workspace_in_tx, replace_policy_workspace, update_policy_workspace,
};
pub use store_canvas_async::{PolicyCanvasDraftSaveResult, save_policy_canvas_draft};
pub use store_sync::load_policy_workspace_sync;

/// The one boundary this crate needs onto the daemon's async connection.
///
/// `AsyncDaemonDb` stays in `harness-daemon` -- this crate only ever gets the
/// policy-graph's own query logic. Depending on `harness-daemon` directly
/// would put a cycle in the workspace graph: `harness-daemon` depends on
/// this crate for its `PolicyGraphQueries` delegates, so this crate can
/// never depend back. `harness-daemon` implements this trait for
/// `AsyncDaemonDb` next to `db`'s own internals, forwarding each method to
/// the pool/transaction primitive it already owns, and every async function
/// in this crate takes `&impl PolicyGraphStore` instead of naming
/// `AsyncDaemonDb` concretely -- the same seam
/// `harness-task-board-provider-sync`'s `ProviderSyncStore` already uses.
pub trait PolicyGraphStore: Send + Sync {
    fn pool(&self) -> &SqlitePool;

    /// # Errors
    /// Returns [`CliError`] when the transaction cannot be started.
    fn begin_immediate_transaction(
        &self,
        context: &str,
    ) -> impl Future<Output = Result<Transaction<'_, Sqlite>, CliError>> + Send;
}

fn db_error(detail: impl Into<Cow<'static, str>>) -> CliError {
    CliError::from(CliErrorKind::workflow_io(detail))
}

fn usize_from_i64(value: i64) -> usize {
    usize::try_from(value).unwrap_or(0)
}
