//! `AsyncDaemonDb`'s implementation of `harness-policy-graph-store`'s
//! `PolicyGraphStore`, so that crate's query logic can run against this
//! daemon's real pool and immediate transactions without either becoming a
//! dependency the extracted crate itself carries (see that crate's own
//! `PolicyGraphStore` doc for why one can't). Lives in `db` rather than
//! next to `PolicyGraphQueries` in `daemon::reviews_store` because
//! `begin_immediate_transaction` is `pub(super)` to `db`, matching how
//! `db/task_board/provider_sync_connection.rs` implements
//! `ProviderSyncStore` for the same reason.

use harness_policy_graph_store::PolicyGraphStore;
use sqlx::{Sqlite, SqlitePool, Transaction};

use super::{AsyncDaemonDb, AsyncDaemonTransactions, CliError};

impl PolicyGraphStore for AsyncDaemonDb {
    fn pool(&self) -> &SqlitePool {
        AsyncDaemonDb::pool(self)
    }

    async fn begin_immediate_transaction(
        &self,
        context: &str,
    ) -> Result<Transaction<'_, Sqlite>, CliError> {
        <Self as AsyncDaemonTransactions>::begin_immediate_transaction(self, context).await
    }
}
