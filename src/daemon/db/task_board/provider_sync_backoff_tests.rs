use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use async_trait::async_trait;
use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;
use crate::task_board::external::ExternalProviderScopeAttemptDecision;
use crate::task_board::{
    ExternalProvider, ExternalSyncClient, ExternalSyncConflictPolicy, ExternalSyncDirection,
    ExternalSyncOptions, ExternalTask, ExternalTaskRef, TaskBoardItem,
};

#[tokio::test]
async fn malformed_persisted_backoff_fails_closed_without_calling_provider() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    set_backoff(&db, "not-a-timestamp").await;
    let calls = Arc::new(AtomicUsize::new(0));
    let clients: Vec<Box<dyn ExternalSyncClient>> =
        vec![Box::new(CountingPullClient::new(Arc::clone(&calls)))];

    let error =
        crate::task_board::external::sync_external_tasks_scoped(&db, pull_options(), &clients)
            .await
            .expect_err("corrupt backoff must stop local sync");

    assert_eq!(error.code(), "WORKFLOW_PARSE");
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn valid_expired_backoff_retries_provider() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    set_backoff(&db, "2000-01-01T00:00:00Z").await;
    let calls = Arc::new(AtomicUsize::new(0));
    let clients: Vec<Box<dyn ExternalSyncClient>> =
        vec![Box::new(CountingPullClient::new(Arc::clone(&calls)))];

    let batch =
        crate::task_board::external::sync_external_tasks_scoped(&db, pull_options(), &clients)
            .await
            .expect("expired backoff permits retry");

    assert_eq!(batch.succeeded_scope_count(), 1);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn missing_persisted_backoff_fails_closed_without_calling_provider() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    set_backoff(&db, "2000-01-01T00:00:00Z").await;
    sqlx::query(
        "UPDATE task_board_provider_scope_state SET backoff_until = NULL
         WHERE provider = 'github' AND scope_id = 'v1:github:read:12:acme/widgets'",
    )
    .execute(db.pool())
    .await
    .expect("clear provider backoff");
    let calls = Arc::new(AtomicUsize::new(0));
    let clients: Vec<Box<dyn ExternalSyncClient>> =
        vec![Box::new(CountingPullClient::new(Arc::clone(&calls)))];

    let error =
        crate::task_board::external::sync_external_tasks_scoped(&db, pull_options(), &clients)
            .await
            .expect_err("missing backoff must stop local sync");

    assert_eq!(error.code(), "WORKFLOW_PARSE");
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}

async fn set_backoff(db: &AsyncDaemonDb, backoff_until: &str) {
    let scope_id = "v1:github:read:12:acme/widgets";
    let attempt = match db
        .begin_task_board_provider_scope_attempt(
            ExternalProvider::GitHub,
            scope_id,
            "2026-07-16T00:00:00Z",
        )
        .await
        .expect("begin provider scope attempt")
    {
        ExternalProviderScopeAttemptDecision::Started(attempt) => attempt,
        other => panic!("expected started attempt, got {other:?}"),
    };
    db.complete_task_board_provider_scope_failure(&attempt, "2026-07-16T00:00:00Z")
        .await
        .expect("create provider scope state");
    sqlx::query(
        "UPDATE task_board_provider_scope_state SET backoff_until = ?1
         WHERE provider = 'github' AND scope_id = ?2",
    )
    .bind(backoff_until)
    .bind(scope_id)
    .execute(db.pool())
    .await
    .expect("set provider backoff");
}

fn pull_options() -> ExternalSyncOptions {
    ExternalSyncOptions {
        status: None,
        provider: Some(ExternalProvider::GitHub),
        direction: ExternalSyncDirection::Pull,
        conflict_policy: ExternalSyncConflictPolicy::Report,
        dry_run: false,
    }
}

struct CountingPullClient {
    calls: Arc<AtomicUsize>,
}

impl CountingPullClient {
    fn new(calls: Arc<AtomicUsize>) -> Self {
        Self { calls }
    }
}

#[async_trait]
impl ExternalSyncClient for CountingPullClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::GitHub
    }

    fn scope_id(&self) -> String {
        "acme/widgets".into()
    }

    fn allows_push(&self) -> bool {
        false
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(Vec::new())
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        unreachable!("pull-only test client")
    }
}
