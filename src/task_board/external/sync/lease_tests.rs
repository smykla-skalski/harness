use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use async_trait::async_trait;

use super::*;
use crate::errors::CliErrorKind;
use crate::task_board::TaskBoardSyncConflict;
use crate::task_board::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision, ExternalProviderScopeState,
    TaskBoardSyncItemSnapshot,
};
use crate::task_board::store::TaskBoardItemPatch;

#[tokio::test]
async fn stale_lease_stops_before_remote_create() {
    let calls = Arc::new(AtomicUsize::new(0));
    let store = StaleLeaseStore {
        item: TaskBoardItem::new(
            "task-lease".into(),
            "Task".into(),
            String::new(),
            "2026-07-16T10:00:00Z".into(),
        ),
        failure_completions: AtomicUsize::new(0),
    };
    let clients: Vec<Box<dyn ExternalSyncClient>> =
        vec![Box::new(CountingCreateClient(Arc::clone(&calls)))];

    let batch = sync_external_tasks_scoped(
        &store,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::GitHub),
            direction: ExternalSyncDirection::Push,
            dry_run: false,
            ..ExternalSyncOptions::default()
        },
        &clients,
    )
    .await
    .expect("stale lease must retain scope evidence");

    assert_eq!(store.failure_completions.load(Ordering::SeqCst), 1);
    let evidence = batch.scope_outcomes[0]
        .error
        .as_deref()
        .expect("stale lease failure evidence");
    assert_eq!(
        batch.scope_outcomes[0].error_code.as_deref(),
        Some("WORKFLOW_CONCURRENT")
    );
    assert!(evidence.contains("provider scope lease was replaced"));
    assert!(evidence.contains("stale provider scope cannot be finalized"));
    let error = batch
        .into_completed()
        .expect_err("stale lease must stop the scope");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert!(
        error
            .details()
            .is_some_and(|details| details.contains("stale provider scope cannot be finalized"))
    );
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}

struct CountingCreateClient(Arc<AtomicUsize>);

#[async_trait]
impl ExternalSyncClient for CountingCreateClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::GitHub
    }

    fn scope_id(&self) -> String {
        "acme/widgets".into()
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        unreachable!("push-only test")
    }

    async fn push_task(&self, item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        self.0.fetch_add(1, Ordering::SeqCst);
        Ok(ExternalTaskRef::new(
            ExternalProvider::GitHub,
            format!("acme/widgets#{}", item.id),
        ))
    }
}

struct StaleLeaseStore {
    item: TaskBoardItem,
    failure_completions: AtomicUsize,
}

#[async_trait]
impl TaskBoardSyncStore for StaleLeaseStore {
    async fn list_items(
        &self,
        _status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(vec![self.item.clone()])
    }

    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(vec![self.item.clone()])
    }

    async fn create_item(&self, _item: TaskBoardItem) -> Result<TaskBoardItem, CliError> {
        unreachable!("push-only test")
    }

    async fn update_item(
        &self,
        _expected_item: &TaskBoardItem,
        _patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        unreachable!("lease fails before local persistence")
    }

    async fn item_snapshot(&self, _item_id: &str) -> Result<TaskBoardSyncItemSnapshot, CliError> {
        Ok(TaskBoardSyncItemSnapshot::new(self.item.clone(), 1))
    }

    async fn provider_scope_state(
        &self,
        _provider: ExternalProvider,
        _scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        Ok(ExternalProviderScopeState::default())
    }

    async fn begin_provider_scope_attempt(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
        _now: &str,
    ) -> Result<ExternalProviderScopeAttemptDecision, CliError> {
        Ok(ExternalProviderScopeAttemptDecision::Started(
            ExternalProviderScopeAttempt::new(
                provider,
                scope_id.to_owned(),
                "stale-fence".into(),
                true,
            ),
        ))
    }

    async fn renew_provider_scope_attempt(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _now: &str,
    ) -> Result<(), CliError> {
        Err(CliErrorKind::concurrent_modification("provider scope lease was replaced").into())
    }

    async fn complete_provider_scope_success(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _base_revision: Option<&str>,
        _completed_at: &str,
    ) -> Result<(), CliError> {
        unreachable!("stale lease never completes")
    }

    async fn complete_provider_scope_failure(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        self.failure_completions.fetch_add(1, Ordering::SeqCst);
        Err(
            CliErrorKind::concurrent_modification("stale provider scope cannot be finalized")
                .into(),
        )
    }

    async fn replace_open_sync_conflicts(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _external_ref: &str,
        _item_revision: i64,
        _conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        unreachable!("lease fails before conflict persistence")
    }
}
