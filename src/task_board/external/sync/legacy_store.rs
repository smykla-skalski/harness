use async_trait::async_trait;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision, ExternalProviderScopeState,
};
use crate::task_board::store::{TaskBoardItemPatch, TaskBoardStore};
use crate::task_board::types::{TaskBoardItem, TaskBoardStatus};
use crate::task_board::{
    ExternalProvider, ExternalSyncField, TaskBoardExternalCreateIntent, TaskBoardSyncConflict,
};

use super::{TaskBoardExternalCreateStore, TaskBoardSyncItemSnapshot, TaskBoardSyncStore};

#[async_trait]
impl TaskBoardExternalCreateStore for TaskBoardStore {
    async fn list_created_external_create_intents(
        &self,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        Ok(Vec::new())
    }

    async fn list_in_flight_external_create_intents(
        &self,
        _provider: ExternalProvider,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        Ok(Vec::new())
    }

    async fn external_create_intent_by_create_key(
        &self,
        _provider: ExternalProvider,
        _create_key: &str,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        Ok(None)
    }

    async fn list_pending_external_create_follow_ups(
        &self,
        _provider: Option<ExternalProvider>,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        Ok(Vec::new())
    }
}

#[async_trait]
impl TaskBoardSyncStore for TaskBoardStore {
    async fn list_items(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        let board = self.clone();
        tokio::task::spawn_blocking(move || board.list(status))
            .await
            .map_err(|error| sync_join_error("list items", error))?
    }

    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        let board = self.clone();
        tokio::task::spawn_blocking(move || board.list_including_deleted())
            .await
            .map_err(|error| sync_join_error("list tombstones", error))?
    }

    async fn list_item_snapshots_including_deleted(
        &self,
    ) -> Result<Vec<TaskBoardSyncItemSnapshot>, CliError> {
        let board = self.clone();
        tokio::task::spawn_blocking(move || {
            board.list_including_deleted().map(|items| {
                items
                    .into_iter()
                    .map(|item| TaskBoardSyncItemSnapshot::new(item, 0))
                    .collect()
            })
        })
        .await
        .map_err(|error| sync_join_error("list snapshot tombstones", error))?
    }

    async fn create_item(&self, item: TaskBoardItem) -> Result<TaskBoardItem, CliError> {
        let board = self.clone();
        tokio::task::spawn_blocking(move || {
            let title = item.title.clone();
            let body = item.body.clone();
            board.create(&title, &body, item)
        })
        .await
        .map_err(|error| sync_join_error("create item", error))?
    }

    async fn update_item(
        &self,
        expected_item: &TaskBoardItem,
        patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        let board = self.clone();
        let expected_item = expected_item.clone();
        tokio::task::spawn_blocking(move || {
            let item_id = expected_item.id.clone();
            board
                .update_if(&item_id, |current| {
                    (current == &expected_item).then_some(patch)
                })?
                .ok_or_else(|| {
                    CliError::from(CliErrorKind::concurrent_modification(format!(
                        "task-board item '{item_id}' changed during external sync"
                    )))
                })
        })
        .await
        .map_err(|error| sync_join_error("update item", error))?
    }

    async fn item_snapshot(&self, item_id: &str) -> Result<TaskBoardSyncItemSnapshot, CliError> {
        let board = self.clone();
        let item_id = item_id.to_owned();
        tokio::task::spawn_blocking(move || {
            board
                .get(&item_id)
                .map(|item| TaskBoardSyncItemSnapshot::new(item, 0))
        })
        .await
        .map_err(|error| sync_join_error("load item snapshot", error))?
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
                format!("test:{provider}:{scope_id}"),
                true,
            ),
        ))
    }

    async fn renew_provider_scope_attempt(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _now: &str,
    ) -> Result<(), CliError> {
        Ok(())
    }

    async fn complete_provider_scope_success(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _base_revision: Option<&str>,
        _completed_at: &str,
    ) -> Result<(), CliError> {
        Ok(())
    }

    async fn complete_provider_scope_failure(
        &self,
        _attempt: &ExternalProviderScopeAttempt,
        _completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        Ok(ExternalProviderScopeState::default())
    }

    async fn replace_open_sync_conflicts(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _external_ref: &str,
        _item_revision: i64,
        _conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        Ok(())
    }

    async fn supersede_open_sync_conflicts(
        &self,
        _item_id: &str,
        _provider: ExternalProvider,
        _external_ref: &str,
        _item_revision: i64,
        _resolved_fields: &[ExternalSyncField],
    ) -> Result<(), CliError> {
        Ok(())
    }
}

fn sync_join_error(operation: &str, error: tokio::task::JoinError) -> CliError {
    CliErrorKind::workflow_io(format!(
        "task-board external sync {operation} worker failed: {error}"
    ))
    .into()
}

#[tokio::test]
async fn non_durable_store_rejects_external_create_admission() {
    let temp = tempfile::tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));

    let error = TaskBoardExternalCreateStore::begin_external_create_intent(
        &board,
        "task-create",
        ExternalProvider::Todoist,
        "todoist:scope",
        "todoist-project",
    )
    .await
    .expect_err("non-durable create admission must fail closed");

    assert_eq!(error.code(), "WORKFLOW_IO");
}
