//! The one boundary this crate needs onto the daemon's storage layer.
//!
//! `AsyncDaemonDb` and the item-lifecycle core it wraps both stay in
//! `harness-daemon` -- this crate only ever gets provider-sync's own query
//! logic. Depending on either directly would put a cycle in the workspace
//! graph: `harness-daemon` depends on this crate for its `ProviderQueries`
//! delegates, so this crate can never depend back on `harness-daemon`.
//! `ProviderSyncStore` is the seam that avoids that -- `harness-daemon`
//! implements it for `AsyncDaemonDb`, forwarding each method to the
//! pool/transaction primitive or item-core helper it already owns, and
//! every function in this crate takes `&impl ProviderSyncStore` instead of
//! naming `AsyncDaemonDb` concretely.
//!
//! The four `_in_tx` methods exist only because their real implementations
//! (`items.rs`, `items_lifecycle.rs`, `items_write.rs`) are `pub(super)`/
//! `pub(crate)` inside `harness-daemon` and stay that way -- widening them
//! to `pub` wouldn't help even if it were desirable, since `db/task_board`
//! itself is a private module with no path out of the crate. Every other
//! area of that seam reaches into the same item-core internals by name
//! today, so a shared, crate-external boundary for all of them is its own,
//! separately scoped problem; this trait is provider-sync's own narrow
//! answer, covering only the handful of helpers this crate calls.

use std::future::Future;

use sqlx::{Sqlite, SqlitePool, Transaction};

use harness_kernel::errors::CliError;
use harness_task_board::TaskBoardItem;

pub trait ProviderSyncStore: Send + Sync {
    fn pool(&self) -> &SqlitePool;

    /// # Errors
    /// Returns [`CliError`] when the transaction cannot be started.
    fn begin_immediate_transaction(
        &self,
        context: &str,
    ) -> impl Future<Output = Result<Transaction<'_, Sqlite>, CliError>> + Send;

    /// # Errors
    /// Returns [`CliError`] on write failure.
    fn bump_change_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        scope: &str,
    ) -> impl Future<Output = Result<i64, CliError>> + Send;

    /// # Errors
    /// Returns [`CliError`] on read failure.
    fn load_item_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        item_id: &str,
    ) -> impl Future<Output = Result<Option<(TaskBoardItem, i64)>, CliError>> + Send;

    /// # Errors
    /// Returns [`CliError`] when the item has a side effect in flight that
    /// forbids this mutation.
    fn ensure_workflow_item_mutation_allowed_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        item_id: &str,
    ) -> impl Future<Output = Result<(), CliError>> + Send;

    /// # Errors
    /// Returns [`CliError`] on write or validation failure.
    fn replace_item_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        item: &TaskBoardItem,
        revision: i64,
    ) -> impl Future<Output = Result<(), CliError>> + Send;
}
