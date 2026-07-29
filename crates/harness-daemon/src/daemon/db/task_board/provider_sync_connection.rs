//! `AsyncDaemonDb`'s implementation of `harness-task-board-provider-sync`'s
//! `ProviderSyncStore`, so that crate's query logic can run against this
//! daemon's real pool/transactions and item-lifecycle core without either
//! becoming a dependency the extracted crate itself carries (see that
//! crate's `store.rs` for why one can't).

use harness_task_board_provider_sync::ProviderSyncStore;
use sqlx::{Sqlite, SqlitePool, Transaction};

use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::TaskBoardItem;

use super::items::{
    bump_change_in_tx, ensure_workflow_item_mutation_allowed_in_tx, load_item_in_tx,
    replace_item_in_tx,
};

impl ProviderSyncStore for AsyncDaemonDb {
    fn pool(&self) -> &SqlitePool {
        AsyncDaemonDb::pool(self)
    }

    async fn begin_immediate_transaction(
        &self,
        context: &str,
    ) -> Result<Transaction<'_, Sqlite>, CliError> {
        AsyncDaemonDb::begin_immediate_transaction(self, context).await
    }

    async fn bump_change_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        scope: &str,
    ) -> Result<i64, CliError> {
        bump_change_in_tx(transaction, scope).await
    }

    async fn load_item_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        item_id: &str,
    ) -> Result<Option<(TaskBoardItem, i64)>, CliError> {
        load_item_in_tx(transaction, item_id).await
    }

    async fn ensure_workflow_item_mutation_allowed_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        item_id: &str,
    ) -> Result<(), CliError> {
        ensure_workflow_item_mutation_allowed_in_tx(transaction, item_id).await
    }

    async fn replace_item_in_tx(
        &self,
        transaction: &mut Transaction<'_, Sqlite>,
        item: &TaskBoardItem,
        revision: i64,
    ) -> Result<(), CliError> {
        replace_item_in_tx(transaction, item, revision).await
    }
}
